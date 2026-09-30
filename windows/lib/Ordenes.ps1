# Órdenes de Aduana. Cada una devuelve su código de retorno y solo llega al sistema a través de
# las funciones de Sistema.ps1.

function Get-AduanaRutaExistente {
    param([Parameter(Mandatory = $true)][string]$Ruta, [switch]$Fichero)
    $tipo = 'Container'
    if ($Fichero) { $tipo = 'Leaf' }
    if (-not (Test-Path -LiteralPath $Ruta -PathType $tipo)) {
        if ($Fichero) { throw (New-AduanaError "No existe el fichero $Ruta.") }
        throw (New-AduanaError "No existe la carpeta $Ruta.")
    }
    return [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $Ruta).ProviderPath)
}

function Get-AduanaColorNivel {
    param([string]$Nivel)
    switch ($Nivel) {
        'peligroso' { return 'Red' }
        'sospechoso' { return 'Yellow' }
        default { return 'Cyan' }
    }
}

# Inspección ---------------------------------------------------------------------------------------

function Get-AduanaConsejo {
    param([string]$Veredicto)
    switch ($Veredicto) {
        'peligroso' { return 'No abras nada de este pendrive con doble clic. Si necesitas algo de él, cópialo con «aduana copiar», que deja fuera lo peligroso.' }
        'sospechoso' { return 'Hay cosas que conviene mirar antes de abrir. Copia lo que necesites con «aduana copiar», para que Windows lo trate como descargado de internet.' }
        default { return 'No se ha encontrado nada preocupante, lo que no garantiza que sea seguro. Copia lo que necesites con «aduana copiar».' }
    }
}

function Get-AduanaTextoAntivirus {
    param($Antivirus)
    switch ($Antivirus.estado) {
        'limpio' { return "Antivirus $($Antivirus.motor), sin detecciones." }
        'detecciones' { return "Antivirus $($Antivirus.motor), con detecciones." }
        'omitido' { return 'Antivirus omitido a petición.' }
        'error' { return "El antivirus falló. $($Antivirus.detalle)" }
        default { return "Antivirus no disponible. $($Antivirus.detalle)" }
    }
}

function Get-AduanaInformeLineas {
    param([Parameter(Mandatory = $true)]$Resultado, $Reglas)
    $lineas = New-Object 'System.Collections.Generic.List[object]'
    $lineas.Add(@{ Texto = "Aduana $($Resultado.aduana), inspección de $(Format-AduanaNombreSeguro $Resultado.ruta $Reglas)"; Color = 'White' })
    $lineas.Add(@{ Texto = "Revisados $($Resultado.resumen.ficheros) ficheros y $($Resultado.resumen.carpetas) carpetas."; Color = '' })
    if ($null -ne $Resultado.dispositivo) {
        $d = $Resultado.dispositivo
        $lineas.Add(@{ Texto = "Dispositivo $($d.bus), $($d.modelo), sistema de ficheros $($d.sistemaFicheros)."; Color = '' })
    }
    foreach ($nivel in @('peligroso', 'sospechoso', 'informativo')) {
        $grupo = @($Resultado.hallazgos | Where-Object { $_.nivel -eq $nivel })
        if ($grupo.Count -eq 0) { continue }
        $color = Get-AduanaColorNivel $nivel
        $lineas.Add(@{ Texto = ''; Color = '' })
        $lineas.Add(@{ Texto = "$($nivel.ToUpperInvariant()) ($($grupo.Count))"; Color = $color })
        foreach ($h in $grupo) {
            $lineas.Add(@{ Texto = "  $(Format-AduanaNombreSeguro $h.ruta $Reglas)"; Color = '' })
            $lineas.Add(@{ Texto = "    $($h.regla): $($h.detalle)"; Color = $color })
        }
    }
    $lineas.Add(@{ Texto = ''; Color = '' })
    $lineas.Add(@{ Texto = (Get-AduanaTextoAntivirus $Resultado.antivirus); Color = '' })
    $lineas.Add(@{ Texto = "Veredicto $($Resultado.veredicto). $(Get-AduanaConsejo $Resultado.veredicto)"; Color = (Get-AduanaColorNivel $Resultado.veredicto) })
    return , $lineas
}

function Invoke-AduanaInspeccion {
    param(
        [Parameter(Mandatory = $true)][string]$Ruta,
        [Parameter(Mandatory = $true)]$Reglas,
        [bool]$Json = $false,
        [bool]$VirusTotal = $false,
        [bool]$SinAntivirus = $false
    )
    $raiz = Get-AduanaRutaExistente -Ruta $Ruta
    $claveVt = $env:VT_API_KEY
    if ($VirusTotal -and -not $claveVt) {
        throw (New-AduanaError 'Para usar --virustotal define antes la variable VT_API_KEY con tu clave de la API.')
    }
    $recorrido = Invoke-AduanaRecorrido -Raiz $raiz -Reglas $Reglas
    $hallazgos = $recorrido.Hallazgos

    $dispositivo = $null
    $d = Get-AduanaDispositivo -Ruta $raiz
    if ($null -ne $d) {
        $dispositivo = $d.Dispositivo
        foreach ($h in (Get-AduanaHallazgosDispositivo -Interfaces $d.Interfaces -ParticionesOcultas $d.ParticionesOcultas)) {
            $hallazgos.Add($h)
        }
    }

    if ($SinAntivirus) {
        $antivirus = [ordered]@{ motor = 'ninguno'; estado = 'omitido'; detalle = 'Se omitió a petición.' }
    }
    else {
        $av = Invoke-AduanaDefender -Ruta $raiz
        if (-not $av.Disponible) {
            $antivirus = [ordered]@{ motor = 'ninguno'; estado = 'no-disponible'; detalle = 'Microsoft Defender no está disponible en este equipo.' }
        }
        else {
            $analisis = ConvertFrom-AduanaSalidaDefender -Salida $av.Salida -Codigo $av.Codigo
            $detalle = 'Sin detecciones.'
            if ($analisis.Estado -eq 'detecciones') { $detalle = "$($analisis.Detecciones.Count) detecciones." }
            if ($analisis.Estado -eq 'error') { $detalle = "MpCmdRun terminó con el código $($av.Codigo)." }
            $antivirus = [ordered]@{ motor = 'Microsoft Defender'; estado = $analisis.Estado; detalle = $detalle }
            foreach ($det in $analisis.Detecciones) {
                $hallazgos.Add((New-AduanaHallazgo 'peligroso' 'antivirus' (Get-AduanaRutaRelativa -Raiz $raiz -Ruta $det.Fichero) $det.Amenaza))
            }
        }
    }

    if ($VirusTotal) {
        foreach ($h in (Invoke-AduanaConsultaVirusTotal -Recorrido $recorrido -Hallazgos $hallazgos -Clave $claveVt)) {
            $hallazgos.Add($h)
        }
    }

    $ordenados = Get-AduanaHallazgosOrdenados -Hallazgos $hallazgos
    $resumen = Get-AduanaResumen -Hallazgos $ordenados -Ficheros $recorrido.Ficheros -Carpetas $recorrido.Carpetas
    $veredicto = Get-AduanaVeredicto -Resumen $resumen
    $resultado = [ordered]@{
        aduana      = (Get-AduanaVersion)
        orden       = 'inspeccionar'
        ruta        = $raiz
        fecha       = (Get-AduanaFecha)
        sistema     = 'windows'
        resumen     = $resumen
        veredicto   = $veredicto.Veredicto
        hallazgos   = $ordenados
        antivirus   = $antivirus
        dispositivo = $dispositivo
    }
    if ($Json) {
        Write-AduanaJson -Json (ConvertTo-AduanaJson -Valor $resultado -Reglas $Reglas)
    }
    else {
        foreach ($l in (Get-AduanaInformeLineas -Resultado $resultado -Reglas $Reglas)) {
            Write-AduanaLinea -Texto $l.Texto -Color $l.Color
        }
    }
    return $veredicto.Codigo
}

function Invoke-AduanaConsultaVirusTotal {
    param($Recorrido, $Hallazgos, [string]$Clave)
    $marcados = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::Ordinal)
    foreach ($h in $Hallazgos) {
        if ($h.nivel -eq 'peligroso' -or $h.nivel -eq 'sospechoso') { [void]$marcados.Add($h.ruta) }
    }
    $candidatos = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $Recorrido.Entradas) {
        if ($e.EsDirectorio -or $e.Enlace -or $e.Artefacto) { continue }
        if ($marcados.Contains($e.Rel) -or $null -ne $e.Firma) { $candidatos.Add($e) }
    }
    $candidatos.Sort([Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Rel, $b.Rel) })
    $nuevos = New-Object 'System.Collections.Generic.List[object]'
    $consultas = 0
    foreach ($e in $candidatos) {
        if ($consultas -ge 20) {
            $nuevos.Add((New-AduanaHallazgo 'informativo' 'virustotal' '.' 'Se han consultado los 20 primeros ficheros; el resto queda sin consultar para respetar el límite de la API gratuita.'))
            break
        }
        # La API gratuita admite cuatro consultas por minuto.
        if ($consultas -gt 0) { Wait-AduanaPausa -Segundos 15 }
        $consultas++
        try {
            $r = Get-AduanaVirusTotal -Hash (Get-AduanaHashFichero -Ruta $e.Completa) -Clave $Clave
        }
        catch {
            $nuevos.Add((New-AduanaHallazgo 'informativo' 'virustotal' $e.Rel "No se pudo consultar VirusTotal. $($_.Exception.Message)"))
            continue
        }
        $nivel = Get-AduanaNivelVirusTotal -Maliciosos $r.Maliciosos
        if ($nivel) {
            $nuevos.Add((New-AduanaHallazgo $nivel 'virustotal' $e.Rel "VirusTotal, $($r.Maliciosos) motores lo marcan como malicioso."))
        }
    }
    return , $nuevos
}

# Copia con marca de origen --------------------------------------------------------------------

function Get-AduanaRutaLibre {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    if (-not (Test-Path -LiteralPath $Ruta)) { return $Ruta }
    $carpeta = [IO.Path]::GetDirectoryName($Ruta)
    $base = [IO.Path]::GetFileNameWithoutExtension($Ruta)
    $ext = [IO.Path]::GetExtension($Ruta)
    for ($i = 2; $i -lt 10000; $i++) {
        $candidata = Join-Path $carpeta ("$base ($i)$ext")
        if (-not (Test-Path -LiteralPath $candidata)) { return $candidata }
    }
    throw (New-AduanaError "No encuentro un nombre libre para $Ruta.")
}

# Ficheros de un paquete sin seguir enlaces ni puntos de unión, que Get-ChildItem -Recurse de
# PowerShell 5.1 sí sigue.
function Get-AduanaFicherosPaquete {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    $ficheros = New-Object 'System.Collections.Generic.List[object]'
    $pila = New-Object 'System.Collections.Generic.Stack[object]'
    $pila.Push((New-Object IO.DirectoryInfo $Ruta))
    while ($pila.Count -gt 0) {
        foreach ($h in $pila.Pop().EnumerateFileSystemInfos()) {
            if (Test-AduanaEnlace -Info $h) { continue }
            if ($h -is [IO.DirectoryInfo]) { $pila.Push($h) } else { $ficheros.Add($h) }
        }
    }
    return , $ficheros
}

function Get-AduanaExtensionesDesinfectables {
    return @('pdf', 'jpg', 'jpeg', 'png', 'gif', 'bmp', 'tif', 'tiff', 'webp', 'odt', 'ods', 'odp')
}

function Invoke-AduanaCopia {
    param(
        [Parameter(Mandatory = $true)][string]$Origen,
        [Parameter(Mandatory = $true)][string]$Destino,
        [Parameter(Mandatory = $true)]$Reglas,
        [bool]$IncluirPeligrosos = $false,
        [bool]$Desinfectar = $false,
        [bool]$Json = $false
    )
    $origenCompleto = Get-AduanaRutaExistente -Ruta $Origen
    $destinoCompleto = [IO.Path]::GetFullPath($Destino)
    if (Test-AduanaRutaDentro -Hija $destinoCompleto -Padre $origenCompleto) {
        throw (New-AduanaError 'El destino no puede estar dentro de lo que se copia.')
    }
    $dangerzone = $null
    if ($Desinfectar) {
        $dangerzone = Find-AduanaDangerzone
        if (-not $dangerzone) {
            throw (New-AduanaError 'Para usar --desinfectar hace falta tener instalado Dangerzone (https://dangerzone.rocks).')
        }
    }
    $recorrido = Invoke-AduanaRecorrido -Raiz $origenCompleto -Reglas $Reglas
    $motivos = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::Ordinal)
    foreach ($h in $recorrido.Hallazgos) {
        if ($h.nivel -ne 'peligroso') { continue }
        if (-not $motivos.ContainsKey($h.ruta)) { $motivos[$h.ruta] = New-Object 'System.Collections.Generic.List[string]' }
        $motivos[$h.ruta].Add($h.regla)
    }

    [void][IO.Directory]::CreateDirectory($destinoCompleto)
    $avisos = New-Object 'System.Collections.Generic.List[string]'
    $omitidos = New-Object 'System.Collections.Generic.List[object]'
    $formato = Get-AduanaSistemaFicheros -Ruta $destinoCompleto
    $marcar = ($formato -eq 'NTFS')
    if (-not $marcar) {
        $avisos.Add("El destino usa $formato, que no admite la marca de origen de Windows. Copia a una carpeta de un disco NTFS para que Windows trate los ficheros como descargados de internet.")
    }
    $desinfectables = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($e in $Reglas.Office) { [void]$desinfectables.Add($e) }
    foreach ($e in (Get-AduanaExtensionesDesinfectables)) { [void]$desinfectables.Add($e) }

    $copiados = 0
    $marcados = 0
    $entradas = New-Object 'System.Collections.Generic.List[object]'
    foreach ($e in $recorrido.Entradas) { $entradas.Add($e) }
    $entradas.Sort([Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Rel, $b.Rel) })
    # Carpetas que no se copian. Nada de lo que hay dentro se copia tampoco, porque recrearlo
    # también recrearía la carpeta con su nombre engañoso.
    $prefijosOmitidos = New-Object 'System.Collections.Generic.List[string]'
    foreach ($e in $entradas) {
        if ($e.Artefacto) { continue }
        $dentroDeOmitida = $false
        foreach ($p in $prefijosOmitidos) {
            if ($e.Rel.StartsWith($p + '/', [StringComparison]::Ordinal)) { $dentroDeOmitida = $true; break }
        }
        if ($dentroDeOmitida) { continue }
        if ($e.Enlace) {
            $omitidos.Add([ordered]@{ ruta = $e.Rel; motivo = 'enlace simbólico, Aduana no lo sigue' })
            continue
        }
        $relNativa = $e.Rel.Replace('/', [IO.Path]::DirectorySeparatorChar)
        $destinoEntrada = [IO.Path]::Combine($destinoCompleto, $relNativa)
        $peligroso = $motivos.ContainsKey($e.Rel)
        if ($peligroso -and -not $IncluirPeligrosos) {
            $omitidos.Add([ordered]@{ ruta = $e.Rel; motivo = ($motivos[$e.Rel] -join ', ') })
            if ($e.EsDirectorio) { $prefijosOmitidos.Add($e.Rel) }
            continue
        }
        # Cada fichero copiado sin marca de origen se avisa, porque es justo lo que Aduana promete.
        $copiadosAhora = New-Object 'System.Collections.Generic.List[string]'
        try {
            if ($e.EsDirectorio) {
                if ($e.Paquete) {
                    # Paquete de macOS incluido a petición: se copia entero y cada fichero lleva la marca.
                    foreach ($f in (Get-AduanaFicherosPaquete -Ruta $e.Completa)) {
                        $relInterna = $f.FullName.Substring($e.Completa.Length).TrimStart('\', '/')
                        $destinoFichero = [IO.Path]::Combine($destinoEntrada, $relInterna)
                        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destinoFichero))
                        [IO.File]::Copy($f.FullName, $destinoFichero, $false)
                        $copiadosAhora.Add($destinoFichero)
                    }
                }
                else {
                    [void][IO.Directory]::CreateDirectory($destinoEntrada)
                }
            }
            else {
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destinoEntrada))
                if ($Desinfectar -and $desinfectables.Contains((Get-AduanaExtension -Nombre $e.Nombre))) {
                    $base = [IO.Path]::GetFileNameWithoutExtension($destinoEntrada)
                    $pdf = Get-AduanaRutaLibre -Ruta (Join-Path ([IO.Path]::GetDirectoryName($destinoEntrada)) "$base-seguro.pdf")
                    $codigo = Invoke-AduanaDangerzone -Programa $dangerzone -Origen $e.Completa -Destino $pdf
                    if ($codigo -ne 0) {
                        $omitidos.Add([ordered]@{ ruta = $e.Rel; motivo = 'Dangerzone no pudo convertirlo' })
                        $avisos.Add("Dangerzone no ha podido convertir $($e.Rel), así que no se ha copiado.")
                    }
                    else {
                        $copiadosAhora.Add($pdf)
                    }
                }
                else {
                    $final = Get-AduanaRutaLibre -Ruta $destinoEntrada
                    [IO.File]::Copy($e.Completa, $final, $false)
                    $copiadosAhora.Add($final)
                }
            }
        }
        catch {
            $avisos.Add("No se ha podido copiar $($e.Rel). $($_.Exception.Message)")
            if ($e.EsDirectorio) { $prefijosOmitidos.Add($e.Rel) }
        }
        foreach ($c in $copiadosAhora) {
            $copiados++
            if (-not $marcar) { continue }
            if (Set-AduanaMarcaOrigen -Ruta $c) {
                $marcados++
            }
            else {
                $avisos.Add("No se ha podido poner la marca de origen a $(Get-AduanaRutaRelativa -Raiz $destinoCompleto -Ruta $c).")
            }
        }
    }

    $resultado = [ordered]@{
        aduana   = (Get-AduanaVersion)
        orden    = 'copiar'
        origen   = $origenCompleto
        destino  = $destinoCompleto
        fecha    = (Get-AduanaFecha)
        sistema  = 'windows'
        copiados = $copiados
        marcados = $marcados
        omitidos = $omitidos
        avisos   = $avisos
    }
    if ($Json) {
        Write-AduanaJson -Json (ConvertTo-AduanaJson -Valor $resultado -Reglas $Reglas)
    }
    else {
        Write-AduanaLinea -Texto "Copiados $copiados ficheros en $(Format-AduanaNombreSeguro $destinoCompleto $Reglas), $marcados con marca de origen."
        if ($omitidos.Count -gt 0) {
            Write-AduanaLinea -Texto ''
            Write-AduanaLinea -Texto "Se han dejado fuera $($omitidos.Count)" -Color 'Yellow'
            foreach ($o in $omitidos) {
                Write-AduanaLinea -Texto "  $(Format-AduanaNombreSeguro $o.ruta $Reglas), por $($o.motivo)"
            }
        }
        foreach ($a in $avisos) {
            Write-AduanaLinea -Texto ''
            Write-AduanaLinea -Texto (Format-AduanaNombreSeguro $a $Reglas) -Color 'Yellow'
        }
    }
    # Con avisos la copia no ha cumplido lo que promete, aunque haya copiado algo.
    if ($avisos.Count -gt 0) { return 3 }
    return 0
}

# Firma y verificación ------------------------------------------------------------------------

function Get-AduanaSshKeygenObligatorio {
    $ssh = Find-AduanaSshKeygen
    if (-not $ssh) {
        throw (New-AduanaError 'Hace falta ssh-keygen, que viene con el Cliente OpenSSH de Windows. Actívalo en Configuración, Sistema, Características opcionales.')
    }
    return $ssh
}

function Invoke-AduanaFirma {
    param(
        [Parameter(Mandatory = $true)][string]$Ruta,
        [Parameter(Mandatory = $true)][string]$Clave,
        [Parameter(Mandatory = $true)]$Reglas
    )
    $raiz = Get-AduanaRutaExistente -Ruta $Ruta
    $privada = Get-AduanaRutaExistente -Ruta $Clave -Fichero
    $publica = "$privada.pub"
    if (-not (Test-Path -LiteralPath $publica -PathType Leaf)) {
        throw (New-AduanaError "No encuentro la clave pública $publica, que tiene que estar junto a la privada.")
    }
    $ssh = Get-AduanaSshKeygenObligatorio
    $firmables = Get-AduanaFicherosFirmables -Raiz $raiz -Reglas $Reglas
    if ($firmables.Enlaces.Count -gt 0) {
        throw (New-AduanaError "No se puede firmar un volumen con enlaces simbólicos o puntos de unión, porque su contenido depende de fuera del pendrive. Quítalos primero ($($firmables.Enlaces -join ', ')).")
    }
    if ($firmables.NombresRaros.Count -gt 0) {
        throw (New-AduanaError 'No se puede firmar un volumen con nombres que contienen saltos de línea. Renómbralos primero.')
    }
    $hashes = Get-AduanaHashesActuales -Ficheros $firmables.Ficheros
    $texto = New-AduanaManifiestoTexto -Hashes $hashes -Fecha (Get-AduanaFecha)
    # Se firma fuera del volumen y solo se lleva al pendrive si la firma sale bien. Así un fallo
    # no deja un manifiesto sin firma ni destruye el que hubiera.
    $temporal = Join-Path ([IO.Path]::GetTempPath()) ('aduana-' + [Guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($temporal)
    try {
        $manifiestoTemporal = Join-Path $temporal 'ADUANA-MANIFIESTO.txt'
        [IO.File]::WriteAllText($manifiestoTemporal, $texto, (New-Object Text.UTF8Encoding $false))
        $codigo = Invoke-AduanaFirmaSsh -SshKeygen $ssh -Clave $privada -Fichero $manifiestoTemporal
        if ($codigo -ne 0 -or -not (Test-Path -LiteralPath "$manifiestoTemporal.sig" -PathType Leaf)) {
            throw (New-AduanaError 'ssh-keygen no ha podido firmar el manifiesto, así que el pendrive queda como estaba.')
        }
        Copy-Item -LiteralPath $manifiestoTemporal -Destination (Join-Path $raiz 'ADUANA-MANIFIESTO.txt') -Force
        Copy-Item -LiteralPath "$manifiestoTemporal.sig" -Destination (Join-Path $raiz 'ADUANA-MANIFIESTO.txt.sig') -Force
        Copy-Item -LiteralPath $publica -Destination (Join-Path $raiz 'ADUANA-CLAVE.pub') -Force
    }
    finally {
        Remove-Item -LiteralPath $temporal -Recurse -Force -ErrorAction SilentlyContinue
    }
    $huella = Get-AduanaHuellaClave -SshKeygen $ssh -Publica $publica
    Write-AduanaLinea -Texto "Firmados $($hashes.Count) ficheros en $(Format-AduanaNombreSeguro $raiz $Reglas)." -Color 'Green'
    Write-AduanaLinea -Texto "La huella de tu clave es $huella. Díctasela a quien reciba el pendrive para que la compare al verificar."
    return 0
}

function Invoke-AduanaVerificacion {
    param(
        [Parameter(Mandatory = $true)][string]$Ruta,
        [Parameter(Mandatory = $true)]$Reglas,
        [string]$Firmantes = '',
        [string]$Confiar = '',
        [bool]$Json = $false
    )
    $raiz = Get-AduanaRutaExistente -Ruta $Ruta
    $manifiesto = Join-Path $raiz 'ADUANA-MANIFIESTO.txt'
    if (-not (Test-Path -LiteralPath $manifiesto -PathType Leaf)) {
        throw (New-AduanaError 'Este pendrive no tiene manifiesto de Aduana, así que no hay nada que verificar.')
    }
    if ($Confiar -and -not (Test-AduanaNombreFirmante -Nombre $Confiar)) {
        throw (New-AduanaError 'El nombre para --confiar no puede llevar espacios, comas, comillas ni asteriscos.')
    }
    if (-not $Firmantes) {
        $Firmantes = Join-Path (Get-AduanaDirectorioEstado) 'firmantes'
    }
    $ssh = Get-AduanaSshKeygenObligatorio
    $bytes = [IO.File]::ReadAllBytes($manifiesto)
    $esperado = ConvertFrom-AduanaManifiesto -Texto ((New-Object Text.UTF8Encoding $false).GetString($bytes))
    $firmables = Get-AduanaFicherosFirmables -Raiz $raiz -Reglas $Reglas
    $extra = @($firmables.Enlaces) + @($firmables.NombresRaros)
    $cambios = Compare-AduanaManifiesto -Esperado $esperado -Actual (Get-AduanaHashesActuales -Ficheros $firmables.Ficheros) -Enlaces $extra

    $firma = [ordered]@{ estado = 'invalida'; firmante = $null; huella = $null }
    $sig = "$manifiesto.sig"
    $pub = Join-Path $raiz 'ADUANA-CLAVE.pub'
    $mensajeConfianza = $null
    if ((Test-Path -LiteralPath $sig -PathType Leaf) -and (Test-Path -LiteralPath $pub -PathType Leaf)) {
        $clave = Get-AduanaClavePublica -Texto ([IO.File]::ReadAllText($pub))
        $temporal = [IO.Path]::GetTempFileName()
        try {
            [IO.File]::WriteAllText($temporal, "aduana-desconocido $($clave.Tipo) $($clave.Material)`n", (New-Object Text.UTF8Encoding $false))
            $r = Invoke-AduanaProceso -Programa $ssh -Argumentos @('-Y', 'verify', '-f', $temporal, '-I', 'aduana-desconocido', '-n', 'aduana', '-s', $sig) -Entrada $bytes
        }
        finally {
            Remove-Item -LiteralPath $temporal -Force -ErrorAction SilentlyContinue
        }
        if ($r.Codigo -ne 0 -and $r.Error) {
            # Lo que diga ssh-keygen ayuda a distinguir una firma falsa de un problema del sistema.
            Write-AduanaError ('ssh-keygen no acepta la firma: ' + (Format-AduanaNombreSeguro -Texto $r.Error.Trim() -Reglas $Reglas))
        }
        if ($r.Codigo -eq 0) {
            $firma.huella = Get-AduanaHuellaClave -SshKeygen $ssh -Publica $pub
            $conocido = Find-AduanaFirmante -Fichero $Firmantes -Tipo $clave.Tipo -Material $clave.Material
            if ($conocido) {
                $firma.estado = 'valida'
                $firma.firmante = $conocido
            }
            elseif ($Confiar) {
                $carpeta = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Firmantes))
                [void][IO.Directory]::CreateDirectory($carpeta)
                [IO.File]::AppendAllText($Firmantes, "$Confiar $($clave.Tipo) $($clave.Material)`n", (New-Object Text.UTF8Encoding $false))
                $firma.estado = 'valida'
                $firma.firmante = $Confiar
                $mensajeConfianza = "He añadido la clave de $Confiar a tus firmantes de confianza."
            }
            else {
                $firma.estado = 'firmante-desconocido'
            }
        }
    }
    $veredicto = 'intacto'
    if ($firma.estado -eq 'invalida' -or $cambios.Count -gt 0) { $veredicto = 'alterado' }
    $codigo = 0
    if ($veredicto -eq 'alterado') { $codigo = 2 }
    elseif ($firma.estado -eq 'firmante-desconocido') { $codigo = 1 }

    $resultado = [ordered]@{
        aduana    = (Get-AduanaVersion)
        orden     = 'verificar'
        ruta      = $raiz
        fecha     = (Get-AduanaFecha)
        sistema   = 'windows'
        firma     = $firma
        cambios   = $cambios
        veredicto = $veredicto
    }
    if ($Json) {
        Write-AduanaJson -Json (ConvertTo-AduanaJson -Valor $resultado -Reglas $Reglas)
        return $codigo
    }
    switch ($firma.estado) {
        'valida' { Write-AduanaLinea -Texto "Firma válida de $($firma.firmante)." -Color 'Green' }
        'firmante-desconocido' { Write-AduanaLinea -Texto "La firma es correcta, pero la clave no está entre tus firmantes de confianza. Su huella es $($firma.huella). Compruébala con quien te dio el pendrive y, si coincide, vuelve a verificar con --confiar y su nombre." -Color 'Yellow' }
        default { Write-AduanaLinea -Texto 'La firma no es válida o falta. No te fíes del contenido del pendrive.' -Color 'Red' }
    }
    if ($mensajeConfianza) { Write-AduanaLinea -Texto $mensajeConfianza }
    foreach ($c in $cambios) {
        Write-AduanaLinea -Texto "  $($c.tipo) $(Format-AduanaNombreSeguro $c.ruta $Reglas)" -Color 'Red'
    }
    if ($veredicto -eq 'intacto') {
        Write-AduanaLinea -Texto 'Veredicto intacto. Nadie ha añadido, quitado ni cambiado nada desde que se firmó.' -Color 'Green'
    }
    else {
        Write-AduanaLinea -Texto 'Veredicto alterado. El contenido no es el que se firmó.' -Color 'Red'
    }
    return $codigo
}

# Equipo ---------------------------------------------------------------------------------------

function Get-AduanaObjetivosEquipo {
    return @(
        @{ Ruta = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Nombre = 'NoDriveTypeAutoRun'; Valor = 255; Tipo = 'DWord'; Descripcion = 'Ejecución automática desactivada en todas las unidades para tu usuario.' }
        @{ Ruta = 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer'; Nombre = 'NoDriveTypeAutoRun'; Valor = 255; Tipo = 'DWord'; Descripcion = 'Ejecución automática desactivada en todas las unidades para todo el equipo.' }
        @{ Ruta = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers'; Nombre = 'DisableAutoplay'; Valor = 1; Tipo = 'DWord'; Descripcion = 'Reproducción automática desactivada.' }
        @{ Ruta = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}'; Nombre = 'Deny_Execute'; Valor = 1; Tipo = 'DWord'; Descripcion = 'Windows ya no ejecuta programas guardados en discos extraíbles.' }
    )
}

# Claves de la ruta que todavía no existen, de la más profunda a la menos. Son las que crea
# preparar-equipo y las únicas que restaurar-equipo puede borrar.
function Get-AduanaClavesAusentes {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    $ausentes = New-Object 'System.Collections.Generic.List[string]'
    $actual = $Ruta
    while ($actual -and -not (Test-AduanaClaveRegistro -Ruta $actual)) {
        $ausentes.Add($actual)
        $i = $actual.LastIndexOf('\')
        if ($i -le 0) { break }
        $actual = $actual.Substring(0, $i)
        if ($actual.EndsWith(':')) { break }
    }
    return , $ausentes
}

function Get-AduanaProfundidadClave {
    param([string]$Ruta)
    return ($Ruta.Split('\')).Count
}

function Get-AduanaFicheroEstadoEquipo {
    return (Join-Path (Get-AduanaDirectorioEstado) 'estado-equipo.json')
}

function Invoke-AduanaPreparacionEquipo {
    param([bool]$SinAutomontaje = $false)
    if (-not (Test-AduanaWindows)) { throw (New-AduanaError 'Esta versión de Aduana es para Windows.') }
    if (-not (Test-AduanaAdmin)) {
        throw (New-AduanaError 'preparar-equipo necesita una consola de PowerShell abierta como administrador.')
    }
    $fichero = Get-AduanaFicheroEstadoEquipo
    $objetivos = Get-AduanaObjetivosEquipo
    $previos = New-Object 'System.Collections.Generic.List[object]'
    $creadas = New-Object 'System.Collections.Generic.List[string]'
    $automontaje = $false
    if (Test-Path -LiteralPath $fichero -PathType Leaf) {
        # Ya se preparó antes. Se conserva el estado original, no el endurecido, para que
        # restaurar-equipo deje el equipo como estaba la primera vez.
        $guardado = [IO.File]::ReadAllText($fichero, [Text.Encoding]::UTF8) | ConvertFrom-Json
        foreach ($v in $guardado.valores) {
            $previos.Add([ordered]@{ ruta = [string]$v.ruta; nombre = [string]$v.nombre; existe = [bool]$v.existe; valor = $v.valor; tipo = $v.tipo })
        }
        $automontaje = [bool]$guardado.automontaje
        if ($guardado.PSObject.Properties['clavesCreadas']) {
            foreach ($c in @($guardado.clavesCreadas)) { if ($c) { $creadas.Add([string]$c) } }
        }
        Write-AduanaLinea -Texto 'El equipo ya estaba preparado. Se vuelven a aplicar los ajustes y se conserva el estado original.'
    }
    else {
        foreach ($o in $objetivos) {
            $actual = Get-AduanaValorRegistro -Ruta $o.Ruta -Nombre $o.Nombre
            $previos.Add([ordered]@{ ruta = $o.Ruta; nombre = $o.Nombre; existe = [bool]$actual.Existe; valor = $actual.Valor; tipo = $actual.Tipo })
            foreach ($c in (Get-AduanaClavesAusentes -Ruta $o.Ruta)) {
                if (-not ($creadas -contains $c)) { $creadas.Add($c) }
            }
        }
    }
    if ($SinAutomontaje) { $automontaje = $true }
    $estado = [ordered]@{ aduana = (Get-AduanaVersion); fecha = (Get-AduanaFecha); valores = $previos; automontaje = $automontaje; clavesCreadas = $creadas }
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fichero))
    [IO.File]::WriteAllText($fichero, (ConvertTo-AduanaJson -Valor $estado), (New-Object Text.UTF8Encoding $false))

    foreach ($o in $objetivos) {
        Set-AduanaValorRegistro -Ruta $o.Ruta -Nombre $o.Nombre -Valor $o.Valor -Tipo $o.Tipo
        Write-AduanaLinea -Texto $o.Descripcion -Color 'Green'
    }
    if ($SinAutomontaje) {
        $null = Invoke-AduanaMountvol -Activar $false
        Write-AduanaLinea -Texto 'Los volúmenes nuevos ya no reciben letra solos. Usa «aduana montar» para montarlos en solo lectura.' -Color 'Green'
    }
    Write-AduanaLinea -Texto ''
    Write-AduanaLinea -Texto 'Puede hacer falta cerrar sesión o reiniciar para que Windows aplique la directiva de discos extraíbles. Para deshacerlo todo, usa «aduana restaurar-equipo».'
    return 0
}

function Invoke-AduanaRestauracionEquipo {
    if (-not (Test-AduanaWindows)) { throw (New-AduanaError 'Esta versión de Aduana es para Windows.') }
    if (-not (Test-AduanaAdmin)) {
        throw (New-AduanaError 'restaurar-equipo necesita una consola de PowerShell abierta como administrador.')
    }
    $fichero = Get-AduanaFicheroEstadoEquipo
    if (-not (Test-Path -LiteralPath $fichero -PathType Leaf)) {
        throw (New-AduanaError 'No hay nada que restaurar, porque preparar-equipo no se ha ejecutado en este equipo.')
    }
    $guardado = [IO.File]::ReadAllText($fichero, [Text.Encoding]::UTF8) | ConvertFrom-Json
    foreach ($v in $guardado.valores) {
        if ([bool]$v.existe) {
            Set-AduanaValorRegistro -Ruta $v.ruta -Nombre $v.nombre -Valor $v.valor -Tipo $v.tipo
        }
        else {
            Remove-AduanaValorRegistro -Ruta $v.ruta -Nombre $v.nombre
        }
    }
    if ([bool]$guardado.automontaje) {
        $null = Invoke-AduanaMountvol -Activar $true
    }
    # Las claves que creó preparar-equipo se borran de la más profunda a la menos, y solo si
    # siguen vacías. Una clave que ya existía nunca está en esta lista.
    if ($guardado.PSObject.Properties['clavesCreadas']) {
        $claves = @($guardado.clavesCreadas | Where-Object { $_ } | Sort-Object -Property @{ Expression = { Get-AduanaProfundidadClave $_ } } -Descending)
        foreach ($c in $claves) {
            Remove-AduanaClaveRegistroVacia -Ruta ([string]$c)
        }
    }
    Remove-Item -LiteralPath $fichero -Force
    Write-AduanaLinea -Texto 'El equipo ha vuelto a la configuración que tenía antes de preparar-equipo.' -Color 'Green'
    return 0
}

# Discos ---------------------------------------------------------------------------------------

# Devuelve el motivo por el que Aduana no debe tocar el disco, o $null si es apto. Se aceptan
# discos USB y discos virtuales montados desde un fichero (VHD), que sirven para las pruebas.
function Get-AduanaMotivoDiscoNoApto {
    param($Disco, [int]$Numero)
    if ($null -eq $Disco) { return "No existe el disco $Numero." }
    if ($Disco.IsSystem -or $Disco.IsBoot) {
        return "El disco $Numero es el del sistema o el de arranque, y Aduana nunca lo toca."
    }
    $bus = [string]$Disco.BusType
    if ($bus -ne 'USB' -and $bus -ne 'File Backed Virtual') {
        return "El disco $Numero no es USB (es $bus), así que Aduana no lo toca."
    }
    return $null
}

function ConvertTo-AduanaNumeroDisco {
    param([string]$Texto)
    $numero = 0
    if (-not [int]::TryParse($Texto, [ref]$numero) -or $numero -lt 0) {
        throw (New-AduanaError "«$Texto» no es un número de disco. Usa «aduana montar» sin argumentos para ver los discos USB.")
    }
    return $numero
}

function Invoke-AduanaMontaje {
    param([string]$Disco = '')
    if (-not (Test-AduanaWindows)) { throw (New-AduanaError 'Esta versión de Aduana es para Windows.') }
    if (-not $Disco) {
        $discos = @(Get-AduanaDiscosExtraibles)
        if ($discos.Count -eq 0) {
            Write-AduanaLinea -Texto 'No hay discos USB conectados.'
            return 0
        }
        foreach ($d in $discos) {
            Write-AduanaLinea -Texto "Disco $($d.Number), $($d.FriendlyName), $(Format-AduanaTamano $d.Size)"
        }
        return 0
    }
    $numero = ConvertTo-AduanaNumeroDisco -Texto $Disco
    $info = Get-AduanaDisco -Numero $numero
    $motivo = Get-AduanaMotivoDiscoNoApto -Disco $info -Numero $numero
    if ($motivo) { throw (New-AduanaError $motivo) }
    if (-not (Set-AduanaDiscoSoloLectura -Numero $numero)) {
        throw (New-AduanaError "Windows no deja poner el disco $numero en solo lectura, algo que pasa con muchos pendrives que se anuncian como medio extraíble. Aduana no lo monta. Si aun así quieres revisarlo, usa «aduana sandbox» o hazlo en una máquina virtual.")
    }
    $letras = @(Add-AduanaLetrasDisco -Numero $numero)
    if ($letras.Count -eq 0) {
        Write-AduanaLinea -Texto "El disco $numero está en solo lectura, pero no tiene ninguna partición que se pueda montar." -Color 'Yellow'
        return 0
    }
    Write-AduanaLinea -Texto "El disco $numero está montado en solo lectura en $((@($letras | ForEach-Object { "${_}:" })) -join ', ')." -Color 'Green'
    return 0
}

function Test-AduanaNombreVolumen {
    param([string]$Nombre)
    return ($Nombre -cmatch '^[\x20-\x7E]{1,11}$' -and $Nombre -notmatch '["*/:<>?\\|]')
}

function Invoke-AduanaPreparacionPendrive {
    param(
        [Parameter(Mandatory = $true)][string]$Disco,
        [string]$Nombre = 'ADUANA',
        [bool]$BorradoCompleto = $false,
        [bool]$Si = $false
    )
    if (-not (Test-AduanaWindows)) { throw (New-AduanaError 'Esta versión de Aduana es para Windows.') }
    if (-not (Test-AduanaNombreVolumen -Nombre $Nombre)) {
        throw (New-AduanaError 'El nombre del volumen tiene que tener entre 1 y 11 caracteres ASCII, sin comillas, barras, dos puntos, asteriscos ni signos de interrogación.')
    }
    $numero = ConvertTo-AduanaNumeroDisco -Texto $Disco
    $info = Get-AduanaDisco -Numero $numero
    $motivo = Get-AduanaMotivoDiscoNoApto -Disco $info -Numero $numero
    if ($motivo) { throw (New-AduanaError $motivo) }
    if (-not $Si) {
        Write-AduanaLinea -Texto "Se va a BORRAR todo el disco $numero ($($info.FriendlyName), $(Format-AduanaTamano $info.Size))." -Color 'Red'
        $respuesta = Read-AduanaConfirmacion -Mensaje 'Para seguir, escribe el número del disco'
        if (([string]$respuesta).Trim() -ne [string]$numero) {
            throw (New-AduanaError 'Cancelado, no has escrito el número del disco.')
        }
    }
    $letra = Invoke-AduanaFormateo -Numero $numero -Nombre $Nombre -Completo $BorradoCompleto
    Write-AduanaLinea -Texto "Listo. El pendrive está en ${letra}: con el nombre $Nombre y sistema de ficheros exFAT." -Color 'Green'
    if ($BorradoCompleto) {
        Write-AduanaLinea -Texto 'Se ha sobrescrito todo el espacio, pero la memoria flash reparte las escrituras y puede guardar copias que el sistema no ve. Si el contenido anterior era delicado, lo seguro es haberlo cifrado.'
    }
    return 0
}

# Limpieza ---------------------------------------------------------------------------------------

function Invoke-AduanaLimpieza {
    param(
        [Parameter(Mandatory = $true)][string]$Ruta,
        [Parameter(Mandatory = $true)]$Reglas,
        [bool]$SoloInforme = $false
    )
    $raiz = Get-AduanaRutaExistente -Ruta $Ruta
    $artefactos = New-Object 'System.Collections.Generic.List[object]'
    $metadatos = New-Object 'System.Collections.Generic.List[object]'
    $pendientes = New-Object 'System.Collections.Generic.List[string]'
    $avisos = New-Object 'System.Collections.Generic.List[string]'
    $ooxml = Get-AduanaExtensionesOoxml
    $conExiftool = @('jpg', 'jpeg', 'png', 'heic', 'tif', 'tiff', 'webp', 'pdf')

    $pila = New-Object 'System.Collections.Generic.Stack[object]'
    $pila.Push(@{ Info = (New-Object IO.DirectoryInfo $raiz); Rel = '' })
    while ($pila.Count -gt 0) {
        $actual = $pila.Pop()
        foreach ($h in @($actual.Info.EnumerateFileSystemInfos())) {
            if ($actual.Rel) { $rel = $actual.Rel + '/' + $h.Name } else { $rel = $h.Name }
            if (Test-AduanaEnlace -Info $h) { continue }
            $esDirectorio = $h -is [IO.DirectoryInfo]
            if ($h.Name -eq 'System Volume Information') { continue }
            # Al preparar un pendrive propio, cualquier «._» es basura de macOS, tenga o no su firma.
            $esArtefacto = $Reglas.Artefactos.Contains($h.Name) -or ($h.Name.StartsWith('._') -and -not $esDirectorio)
            if (-not $esArtefacto -and -not $esDirectorio -and $h.Name -eq 'desktop.ini') {
                $contenido = Get-AduanaHallazgosContenido -Ruta $h.FullName -Nombre $h.Name -Cabecera $null -Reglas $Reglas
                if ($contenido[0].Regla -eq 'artefacto-sistema') { $esArtefacto = $true }
                else { $avisos.Add("$rel asocia la carpeta a un componente del sistema. Revísalo, porque Aduana no lo borra.") }
            }
            if ($esArtefacto) {
                $artefactos.Add(@{ Rel = $rel; Completa = $h.FullName })
                continue
            }
            if ($esDirectorio) {
                $pila.Push(@{ Info = $h; Rel = $rel })
                continue
            }
            $ext = Get-AduanaExtension -Nombre $h.Name
            $campos = New-Object 'System.Collections.Generic.List[string]'
            if ($ooxml -contains $ext) {
                foreach ($c in (Get-AduanaMetadatosOoxml -Ruta $h.FullName)) { $campos.Add($c) }
            }
            elseif ($ext -eq 'jpg' -or $ext -eq 'jpeg') {
                if (Test-AduanaGpsJpeg -Bytes (Read-AduanaBytes -Ruta $h.FullName -Maximo 256KB)) { $campos.Add('ubicación GPS') }
            }
            elseif ($ext -eq 'pdf') {
                $texto = [Text.Encoding]::GetEncoding(28591).GetString((Read-AduanaBytes -Ruta $h.FullName -Maximo 1MB))
                foreach ($c in (Get-AduanaMetadatosPdf -Texto $texto)) { $campos.Add($c) }
            }
            if ($campos.Count -gt 0) {
                $metadatos.Add(@{ Rel = $rel; Completa = $h.FullName; Campos = $campos; Ooxml = ($ooxml -contains $ext) })
            }
            if ($conExiftool -contains $ext) {
                $pendientes.Add($h.FullName)
            }
        }
    }

    $exiftool = Find-AduanaExiftool
    Write-AduanaLinea -Texto "Aduana $(Get-AduanaVersion), limpieza de $(Format-AduanaNombreSeguro $raiz $Reglas)" -Color 'White'
    if ($artefactos.Count -eq 0) {
        Write-AduanaLinea -Texto 'No hay ficheros basura del sistema.'
    }
    else {
        Write-AduanaLinea -Texto "Ficheros basura del sistema ($($artefactos.Count))" -Color 'Yellow'
        foreach ($a in $artefactos) {
            if ($SoloInforme) {
                Write-AduanaLinea -Texto "  $(Format-AduanaNombreSeguro $a.Rel $Reglas)"
                continue
            }
            try {
                Remove-Item -LiteralPath $a.Completa -Recurse -Force -ErrorAction Stop
                Write-AduanaLinea -Texto "  borrado $(Format-AduanaNombreSeguro $a.Rel $Reglas)"
            }
            catch {
                $avisos.Add("No se ha podido borrar $($a.Rel). $($_.Exception.Message)")
            }
        }
    }
    if ($metadatos.Count -eq 0) {
        Write-AduanaLinea -Texto 'No se han encontrado metadatos personales en documentos de Office, fotos JPEG ni PDF.'
    }
    else {
        Write-AduanaLinea -Texto "Metadatos personales ($($metadatos.Count))" -Color 'Yellow'
        foreach ($m in $metadatos) {
            Write-AduanaLinea -Texto "  $(Format-AduanaNombreSeguro $m.Rel $Reglas), $($m.Campos -join ', ')"
            if (-not $SoloInforme -and $m.Ooxml) {
                try {
                    Clear-AduanaMetadatosOoxml -Ruta $m.Completa
                    Write-AduanaLinea -Texto '    limpiado'
                }
                catch {
                    $avisos.Add("No se han podido quitar los metadatos de $($m.Rel). $($_.Exception.Message)")
                }
            }
        }
    }
    if ($pendientes.Count -gt 0) {
        if ($SoloInforme) {
            Write-AduanaLinea -Texto "Hay $($pendientes.Count) fotos o PDF cuyos metadatos solo se pueden quitar con exiftool."
        }
        elseif ($exiftool) {
            $limpios = 0
            foreach ($p in $pendientes) {
                if ((Invoke-AduanaExiftool -Programa $exiftool -Ruta $p) -eq 0) { $limpios++ }
            }
            Write-AduanaLinea -Texto "exiftool ha quitado los metadatos de $limpios de $($pendientes.Count) fotos y PDF." -Color 'Green'
        }
        else {
            $avisos.Add("Hay $($pendientes.Count) fotos o PDF de los que Aduana no sabe quitar metadatos sin exiftool. Instálalo desde https://exiftool.org y vuelve a limpiar.")
        }
    }
    foreach ($a in $avisos) {
        Write-AduanaLinea -Texto (Format-AduanaNombreSeguro $a $Reglas) -Color 'Yellow'
    }
    return 0
}

# Capacidad ----------------------------------------------------------------------------------------

function Invoke-AduanaCapacidad {
    param(
        [Parameter(Mandatory = $true)][string]$Ruta,
        [string]$LimiteMb = ''
    )
    $raiz = Get-AduanaRutaExistente -Ruta $Ruta
    $tamano = Get-AduanaTamanoBloqueCapacidad
    $libre = Get-AduanaEspacioLibre -Ruta $raiz
    $total = [long]$libre - $tamano
    if ($LimiteMb) {
        $limite = 0
        if (-not [int]::TryParse($LimiteMb, [ref]$limite) -or $limite -le 0) {
            throw (New-AduanaError '--limite tiene que ser un número de megas mayor que cero.')
        }
        $total = [Math]::Min($total, [long]$limite * $tamano)
    }
    $total = [long][Math]::Floor($total / $tamano) * $tamano
    if ($total -le 0) {
        throw (New-AduanaError 'No hay espacio libre que comprobar.')
    }
    $semilla = [Guid]::NewGuid().ToString('N')
    Write-AduanaLinea -Texto "Escribiendo $(Format-AduanaTamano $total) de datos de prueba. Puede tardar un buen rato."
    $escritura = $null
    try {
        $escritura = Write-AduanaDatosCapacidad -Raiz $raiz -Total $total -Semilla $semilla
        Clear-AduanaCacheDisco -Ruta $raiz
        $lectura = Test-AduanaDatosCapacidad -Ficheros $escritura.Ficheros -Huellas $escritura.Huellas
    }
    finally {
        # Se borran los datos de prueba pase lo que pase, también si se interrumpe.
        foreach ($i in 1..9999) {
            $f = Join-Path $raiz (Get-AduanaNombreCapacidad -Indice $i)
            if (-not (Test-Path -LiteralPath $f)) { break }
            Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
        }
    }
    Write-AduanaLinea -Texto "Escritos $(Format-AduanaTamano $escritura.Escritos), leídos bien $(Format-AduanaTamano $lectura.Verificados)."
    if ($lectura.Verificados -lt $escritura.Escritos) {
        Write-AduanaLinea -Texto "El pendrive solo guarda bien los primeros $(Format-AduanaTamano $lectura.PrimerFallo). Declara más capacidad de la real o está dañado, así que no lo uses para nada importante." -Color 'Red'
        return 2
    }
    Write-AduanaLinea -Texto 'Todo lo escrito se ha leído bien.' -Color 'Green'
    return 0
}

# Cifrado, centinela y sandbox ----------------------------------------------------------------------

function Invoke-AduanaCifrado {
    param([Parameter(Mandatory = $true)][string]$Carpeta, [string]$Salida = '')
    $origen = Get-AduanaRutaExistente -Ruta $Carpeta
    $programa = Find-Aduana7z
    if (-not $programa) {
        throw (New-AduanaError 'Para cifrar hace falta 7-Zip. Instálalo desde https://www.7-zip.org y vuelve a intentarlo.')
    }
    if (-not $Salida) { $Salida = $origen.TrimEnd('\', '/') + '.7z' }
    $Salida = [IO.Path]::GetFullPath($Salida)
    if (Test-Path -LiteralPath $Salida) {
        throw (New-AduanaError "Ya existe $Salida y Aduana no lo sobrescribe.")
    }
    Write-AduanaLinea -Texto '7-Zip te pedirá una contraseña. Usa una larga y compártela por otro canal, nunca en el propio pendrive.'
    $codigo = Invoke-Aduana7z -Programa $programa -Salida $Salida -Carpeta $origen
    if ($codigo -ne 0) {
        throw (New-AduanaError "7-Zip terminó con el código $codigo y el fichero cifrado puede estar incompleto.")
    }
    Write-AduanaLinea -Texto "Cifrado en $Salida con AES-256, nombres de fichero incluidos." -Color 'Green'
    return 0
}

function Get-AduanaTecladosConocidos {
    $fichero = Join-Path (Get-AduanaDirectorioEstado) 'teclados-conocidos.txt'
    $ids = New-Object 'System.Collections.Generic.List[string]'
    if (Test-Path -LiteralPath $fichero -PathType Leaf) {
        foreach ($l in [IO.File]::ReadAllLines($fichero)) {
            $id = Get-AduanaIdTeclado -Texto $l
            if ($id -and -not $ids.Contains($id)) { $ids.Add($id) }
        }
    }
    return , $ids
}

function Invoke-AduanaCentinela {
    param([string]$Durante = '', [bool]$Aprender = $false)
    if (-not (Test-AduanaWindows)) { throw (New-AduanaError 'Esta versión de Aduana es para Windows.') }
    $conocidos = Get-AduanaTecladosConocidos
    foreach ($id in (Get-AduanaTecladosPresentes)) {
        if (-not $conocidos.Contains($id)) { $conocidos.Add($id) }
    }
    if ($Aprender) {
        $fichero = Join-Path (Get-AduanaDirectorioEstado) 'teclados-conocidos.txt'
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($fichero))
        [IO.File]::WriteAllLines($fichero, $conocidos.ToArray())
        Write-AduanaLinea -Texto "Guardados $($conocidos.Count) teclados como conocidos." -Color 'Green'
        return 0
    }
    $segundos = 60
    if ($Durante -and (-not [int]::TryParse($Durante, [ref]$segundos) -or $segundos -lt 5 -or $segundos -gt 3600)) {
        throw (New-AduanaError '--durante tiene que ser un número de segundos entre 5 y 3600.')
    }
    Write-AduanaLinea -Texto "Centinela armado durante $segundos segundos. Conecta ahora el pendrive. Si aparece un teclado nuevo, bloquearé la sesión." -Color 'Yellow'
    $r = Start-AduanaCentinela -Segundos $segundos -Conocidos $conocidos.ToArray()
    if ($r.Disparado) {
        Write-AduanaLinea -Texto "Ha aparecido un teclado desconocido ($($r.Dispositivo)) y he bloqueado la sesión. Desconecta el pendrive antes de volver a entrar." -Color 'Red'
        return 2
    }
    Write-AduanaLinea -Texto 'No ha aparecido ningún teclado nuevo.' -Color 'Green'
    return 0
}

function Invoke-AduanaSandbox {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    $origen = Get-AduanaRutaExistente -Ruta $Ruta
    $sandbox = Find-AduanaSandbox
    if (-not $sandbox) {
        throw (New-AduanaError 'Windows Sandbox no está disponible. Requiere Windows Pro, Enterprise o Education y activarlo en Características de Windows.')
    }
    $configuracion = Join-Path ([IO.Path]::GetTempPath()) ("aduana-{0}.wsb" -f (Get-Date -Format 'yyyyMMddHHmmss'))
    [IO.File]::WriteAllText($configuracion, (New-AduanaConfiguracionSandbox -Ruta $origen), (New-Object Text.UTF8Encoding $false))
    Start-AduanaSandbox -Configuracion $configuracion
    Write-AduanaLinea -Texto 'Abriendo Windows Sandbox con el pendrive en el escritorio, en solo lectura y sin red. Todo lo que hagas dentro desaparece al cerrarla.' -Color 'Green'
    return 0
}

# Punto de entrada -------------------------------------------------------------------------------

function Invoke-Aduana {
    param(
        [AllowNull()][AllowEmptyCollection()][string[]]$Argumentos,
        [Parameter(Mandatory = $true)][string]$Raiz
    )
    try {
        [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false
    }
    catch {
        Write-Verbose 'Esta consola no permite cambiar la codificación.'
    }
    try {
        $p = ConvertFrom-AduanaArgumentos -Argumentos $Argumentos
        $o = $p.Opciones
        $pos = $p.Posicionales
        $rutaReglas = Join-Path (Join-Path $Raiz 'reglas') 'reglas.json'
        switch ($p.Orden) {
            'ayuda' {
                foreach ($l in (Get-AduanaAyuda)) { Write-AduanaLinea -Texto $l }
                return 0
            }
            'version' {
                Write-AduanaLinea -Texto (Get-AduanaVersion)
                return 0
            }
            'preparar-equipo' { return (Invoke-AduanaPreparacionEquipo -SinAutomontaje ([bool]$o['sin-automontaje'])) }
            'restaurar-equipo' { return (Invoke-AduanaRestauracionEquipo) }
            'montar' {
                $disco = ''
                if ($pos.Count -gt 0) { $disco = $pos[0] }
                return (Invoke-AduanaMontaje -Disco $disco)
            }
            'inspeccionar' {
                return (Invoke-AduanaInspeccion -Ruta $pos[0] -Reglas (Import-AduanaReglas -Ruta $rutaReglas) -Json ([bool]$o['json']) -VirusTotal ([bool]$o['virustotal']) -SinAntivirus ([bool]$o['sin-antivirus']))
            }
            'copiar' {
                return (Invoke-AduanaCopia -Origen $pos[0] -Destino $pos[1] -Reglas (Import-AduanaReglas -Ruta $rutaReglas) -IncluirPeligrosos ([bool]$o['incluir-peligrosos']) -Desinfectar ([bool]$o['desinfectar']) -Json ([bool]$o['json']))
            }
            'verificar' {
                return (Invoke-AduanaVerificacion -Ruta $pos[0] -Reglas (Import-AduanaReglas -Ruta $rutaReglas) -Firmantes ([string]$o['firmantes']) -Confiar ([string]$o['confiar']) -Json ([bool]$o['json']))
            }
            'salida-preparar' {
                $nombre = 'ADUANA'
                if ($o['nombre']) { $nombre = [string]$o['nombre'] }
                return (Invoke-AduanaPreparacionPendrive -Disco $pos[0] -Nombre $nombre -BorradoCompleto ([bool]$o['borrado-completo']) -Si ([bool]$o['si']))
            }
            'salida-limpiar' { return (Invoke-AduanaLimpieza -Ruta $pos[0] -Reglas (Import-AduanaReglas -Ruta $rutaReglas) -SoloInforme ([bool]$o['solo-informe'])) }
            'salida-comprobar-capacidad' { return (Invoke-AduanaCapacidad -Ruta $pos[0] -LimiteMb ([string]$o['limite'])) }
            'salida-firmar' {
                if (-not $o['clave']) { throw (New-AduanaError 'Falta --clave con la ruta de tu clave privada SSH.') }
                return (Invoke-AduanaFirma -Ruta $pos[0] -Clave ([string]$o['clave']) -Reglas (Import-AduanaReglas -Ruta $rutaReglas))
            }
            'salida-cifrar' { return (Invoke-AduanaCifrado -Carpeta $pos[0] -Salida ([string]$o['salida'])) }
            'centinela' { return (Invoke-AduanaCentinela -Durante ([string]$o['durante']) -Aprender ([bool]$o['aprender'])) }
            'sandbox' { return (Invoke-AduanaSandbox -Ruta $pos[0]) }
        }
        throw (New-AduanaError "Orden sin implementar: $($p.Orden).")
    }
    catch {
        $excepcion = $_.Exception
        if ($excepcion.Data.Contains('AduanaCodigo')) {
            Write-AduanaError -Texto $excepcion.Message
            return [int]$excepcion.Data['AduanaCodigo']
        }
        Write-AduanaError -Texto "Error inesperado. $($excepcion.Message)"
        return 3
    }
}

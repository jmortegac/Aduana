# Ayudantes de las órdenes de salida: metadatos de documentos y fotos, y datos de prueba para
# comprobar la capacidad real de un pendrive. No tocan Windows, así que se prueban en Linux.

function Get-AduanaExtensionesOoxml {
    return @('docx', 'docm', 'dotx', 'dotm', 'xlsx', 'xlsm', 'xltx', 'xltm', 'xlam', 'pptx', 'pptm', 'potx', 'potm', 'ppsx', 'ppsm', 'ppam', 'sldm')
}

function Get-AduanaEtiquetasMetadatos {
    # Etiqueta XML y cómo se llama en el informe.
    return [ordered]@{ 'dc:creator' = 'autor'; 'cp:lastModifiedBy' = 'modificado por'; 'Company' = 'empresa'; 'Manager' = 'responsable' }
}

function Get-AduanaMetadatosXml {
    param([AllowEmptyString()][string]$Xml)
    $campos = New-Object 'System.Collections.Generic.List[string]'
    if (-not $Xml) { return , $campos }
    $etiquetas = Get-AduanaEtiquetasMetadatos
    foreach ($etiqueta in $etiquetas.Keys) {
        $patron = '<' + [regex]::Escape($etiqueta) + '(?:\s[^>]*)?>([^<]*)</' + [regex]::Escape($etiqueta) + '>'
        $m = [regex]::Match($Xml, $patron)
        if ($m.Success -and $m.Groups[1].Value.Trim()) {
            $campos.Add("$($etiquetas[$etiqueta]) «$($m.Groups[1].Value.Trim())»")
        }
    }
    return , $campos
}

function Remove-AduanaMetadatosXml {
    param([AllowEmptyString()][string]$Xml)
    if (-not $Xml) { return $Xml }
    $resultado = $Xml
    foreach ($etiqueta in (Get-AduanaEtiquetasMetadatos).Keys) {
        $e = [regex]::Escape($etiqueta)
        $resultado = [regex]::Replace($resultado, "(<$e(?:\s[^>]*)?>)[^<]*(</$e>)", '$1$2')
    }
    return $resultado
}

function Read-AduanaEntradaZip {
    param($Zip, [string]$Nombre)
    $entrada = $Zip.GetEntry($Nombre)
    if ($null -eq $entrada) { return '' }
    $lector = New-Object IO.StreamReader($entrada.Open(), [Text.Encoding]::UTF8)
    try { return $lector.ReadToEnd() } finally { $lector.Dispose() }
}

function Get-AduanaMetadatosOoxml {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    Initialize-AduanaCompresion
    $campos = New-Object 'System.Collections.Generic.List[string]'
    try {
        $zip = [IO.Compression.ZipFile]::OpenRead($Ruta)
    }
    catch {
        return , $campos
    }
    try {
        foreach ($nombre in @('docProps/core.xml', 'docProps/app.xml')) {
            foreach ($c in (Get-AduanaMetadatosXml -Xml (Read-AduanaEntradaZip -Zip $zip -Nombre $nombre))) { $campos.Add($c) }
        }
    }
    finally {
        $zip.Dispose()
    }
    return , $campos
}

function Clear-AduanaMetadatosOoxml {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    Initialize-AduanaCompresion
    $zip = [IO.Compression.ZipFile]::Open($Ruta, [IO.Compression.ZipArchiveMode]::Update)
    try {
        foreach ($nombre in @('docProps/core.xml', 'docProps/app.xml')) {
            $original = Read-AduanaEntradaZip -Zip $zip -Nombre $nombre
            if (-not $original) { continue }
            $limpio = Remove-AduanaMetadatosXml -Xml $original
            if ($limpio -ceq $original) { continue }
            $zip.GetEntry($nombre).Delete()
            $nueva = $zip.CreateEntry($nombre, [IO.Compression.CompressionLevel]::Optimal)
            $escritor = New-Object IO.StreamWriter($nueva.Open(), (New-Object Text.UTF8Encoding $false))
            try { $escritor.Write($limpio) } finally { $escritor.Dispose() }
        }
    }
    finally {
        $zip.Dispose()
    }
}

# EXIF de un JPEG: busca en el bloque APP1 el puntero al directorio GPS (etiqueta 0x8825) y mira
# si ese directorio trae latitud o longitud (etiquetas 1 a 4). Se analiza a mano para no depender
# de System.Drawing, que no existe fuera de Windows.
function Test-AduanaGpsJpeg {
    param([byte[]]$Bytes)
    try {
        if ($null -eq $Bytes -or $Bytes.Length -lt 4 -or $Bytes[0] -ne 0xff -or $Bytes[1] -ne 0xd8) { return $false }
        $i = 2
        while ($i + 4 -le $Bytes.Length) {
            if ($Bytes[$i] -ne 0xff) { return $false }
            $marcador = $Bytes[$i + 1]
            if ($marcador -eq 0xd9 -or $marcador -eq 0xda) { return $false }
            $largo = ([int]$Bytes[$i + 2] -shl 8) -bor [int]$Bytes[$i + 3]
            if ($marcador -eq 0xe1 -and $largo -ge 16 -and
                $Bytes[$i + 4] -eq 0x45 -and $Bytes[$i + 5] -eq 0x78 -and $Bytes[$i + 6] -eq 0x69 -and $Bytes[$i + 7] -eq 0x66) {
                return (Test-AduanaGpsTiff -Bytes $Bytes -Tiff ($i + 10))
            }
            $i += 2 + $largo
        }
    }
    catch {
        return $false
    }
    return $false
}

function Read-AduanaEntero {
    param([byte[]]$Bytes, [int]$Posicion, [int]$Tamano, [bool]$Intel)
    $valor = [long]0
    for ($k = 0; $k -lt $Tamano; $k++) {
        if ($Intel) { $b = $Bytes[$Posicion + $Tamano - 1 - $k] } else { $b = $Bytes[$Posicion + $k] }
        $valor = ($valor -shl 8) -bor [long]$b
    }
    return $valor
}

function Test-AduanaGpsTiff {
    param([byte[]]$Bytes, [int]$Tiff)
    $intel = ($Bytes[$Tiff] -eq 0x49)
    $ifd0 = Read-AduanaEntero -Bytes $Bytes -Posicion ($Tiff + 4) -Tamano 4 -Intel $intel
    $n = Read-AduanaEntero -Bytes $Bytes -Posicion ($Tiff + $ifd0) -Tamano 2 -Intel $intel
    for ($k = 0; $k -lt $n; $k++) {
        $entrada = $Tiff + $ifd0 + 2 + 12 * $k
        if ((Read-AduanaEntero -Bytes $Bytes -Posicion $entrada -Tamano 2 -Intel $intel) -eq 0x8825) {
            $gps = Read-AduanaEntero -Bytes $Bytes -Posicion ($entrada + 8) -Tamano 4 -Intel $intel
            $m = Read-AduanaEntero -Bytes $Bytes -Posicion ($Tiff + $gps) -Tamano 2 -Intel $intel
            for ($j = 0; $j -lt $m; $j++) {
                $etiqueta = Read-AduanaEntero -Bytes $Bytes -Posicion ($Tiff + $gps + 2 + 12 * $j) -Tamano 2 -Intel $intel
                if ($etiqueta -ge 1 -and $etiqueta -le 4) { return $true }
            }
            return $false
        }
    }
    return $false
}

function Get-AduanaMetadatosPdf {
    param([AllowEmptyString()][string]$Texto)
    $campos = New-Object 'System.Collections.Generic.List[string]'
    $m = [regex]::Match($Texto, '/Author\s*\(([^)]*)\)')
    if ($m.Success -and $m.Groups[1].Value.Trim()) {
        $campos.Add("autor «$($m.Groups[1].Value.Trim())»")
    }
    elseif ([regex]::IsMatch($Texto, '/Author\s*<[0-9A-Fa-f]{4,}>')) {
        $campos.Add('autor (codificado)')
    }
    $x = [regex]::Match($Texto, '<dc:creator>[\s\S]*?<rdf:li[^>]*>([^<]+)</rdf:li>')
    if ($x.Success -and $campos.Count -eq 0) {
        $campos.Add("autor «$($x.Groups[1].Value.Trim())»")
    }
    return , $campos
}

# Comprobación de capacidad ---------------------------------------------------------------------
# Cada bloque de 1 MiB es único: AES-CBC cifrando ceros con una clave por fichero y un vector
# inicial por bloque. Un pendrive falso que al llenarse vuelve a escribir sobre el principio
# devuelve bloques que no casan con su huella y queda al descubierto.

function Get-AduanaTamanoBloqueCapacidad { return 1048576 }

function New-AduanaGeneradorCapacidad {
    param([Parameter(Mandatory = $true)][string]$Semilla)
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.Mode = [Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [Security.Cryptography.PaddingMode]::None
    return @{ Aes = $aes; Semilla = $Semilla; Ceros = (New-Object byte[] (Get-AduanaTamanoBloqueCapacidad)); Sha = [Security.Cryptography.SHA256]::Create() }
}

function Get-AduanaBloqueCapacidad {
    param($Generador, [int]$Fichero, [long]$Bloque)
    $sha = $Generador.Sha
    $clave = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("aduana|$($Generador.Semilla)|$Fichero"))
    $semillaIv = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes("aduana|$($Generador.Semilla)|$Fichero|$Bloque"))
    $iv = New-Object byte[] 16
    [Array]::Copy($semillaIv, $iv, 16)
    $cifrador = $Generador.Aes.CreateEncryptor($clave, $iv)
    try {
        $salida = New-Object byte[] $Generador.Ceros.Length
        [void]$cifrador.TransformBlock($Generador.Ceros, 0, $Generador.Ceros.Length, $salida, 0)
        return , $salida
    }
    finally {
        $cifrador.Dispose()
    }
}

function Get-AduanaNombreCapacidad {
    param([int]$Indice)
    return ('ADUANA-CAPACIDAD-{0:D4}.bin' -f $Indice)
}

function Write-AduanaDatosCapacidad {
    param(
        [Parameter(Mandatory = $true)][string]$Raiz,
        [Parameter(Mandatory = $true)][long]$Total,
        [Parameter(Mandatory = $true)][string]$Semilla,
        [int]$BloquesPorFichero = 1024
    )
    $tamano = Get-AduanaTamanoBloqueCapacidad
    $generador = New-AduanaGeneradorCapacidad -Semilla $Semilla
    $ficheros = New-Object 'System.Collections.Generic.List[string]'
    $huellas = New-Object 'System.Collections.Generic.List[string]'
    $bloques = [long][Math]::Floor($Total / $tamano)
    $escrito = [long]0
    $indice = 0
    try {
        while ($escrito -lt $bloques * $tamano) {
            $indice++
            $ruta = Join-Path $Raiz (Get-AduanaNombreCapacidad -Indice $indice)
            $ficheros.Add($ruta)
            $flujo = New-Object IO.FileStream($ruta, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None, $tamano, [IO.FileOptions]::WriteThrough)
            try {
                for ($b = 0; $b -lt $BloquesPorFichero -and $escrito -lt $bloques * $tamano; $b++) {
                    $datos = Get-AduanaBloqueCapacidad -Generador $generador -Fichero $indice -Bloque $b
                    $flujo.Write($datos, 0, $datos.Length)
                    $huellas.Add([BitConverter]::ToString($generador.Sha.ComputeHash($datos)))
                    $escrito += $tamano
                    if (($huellas.Count % 64) -eq 0) {
                        Write-Progress -Activity 'Escribiendo datos de prueba' -Status (Format-AduanaTamano $escrito) -PercentComplete ([int](100 * $escrito / ($bloques * $tamano)))
                    }
                }
                $flujo.Flush($true)
            }
            finally {
                $flujo.Dispose()
            }
        }
    }
    finally {
        $generador.Aes.Dispose()
        Write-Progress -Activity 'Escribiendo datos de prueba' -Completed
    }
    return @{ Ficheros = $ficheros; Huellas = $huellas; Escritos = $escrito }
}

function Test-AduanaDatosCapacidad {
    param(
        [Parameter(Mandatory = $true)]$Ficheros,
        [Parameter(Mandatory = $true)]$Huellas,
        [int]$BloquesPorFichero = 1024
    )
    $tamano = Get-AduanaTamanoBloqueCapacidad
    $sha = [Security.Cryptography.SHA256]::Create()
    $buffer = New-Object byte[] $tamano
    $verificados = [long]0
    $primerFallo = [long]-1
    $n = 0
    foreach ($ruta in $Ficheros) {
        $flujo = New-Object IO.FileStream($ruta, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read, $tamano)
        try {
            for ($b = 0; $b -lt $BloquesPorFichero -and $n -lt $Huellas.Count; $b++) {
                $leidos = 0
                while ($leidos -lt $tamano) {
                    $r = $flujo.Read($buffer, $leidos, $tamano - $leidos)
                    if ($r -le 0) { break }
                    $leidos += $r
                }
                if ($leidos -eq 0) { break }
                $bien = ($leidos -eq $tamano -and [BitConverter]::ToString($sha.ComputeHash($buffer)) -eq $Huellas[$n])
                if ($bien) {
                    $verificados += $tamano
                }
                elseif ($primerFallo -lt 0) {
                    $primerFallo = [long]$n * $tamano
                }
                $n++
                if (($n % 64) -eq 0) {
                    Write-Progress -Activity 'Leyendo datos de prueba' -Status (Format-AduanaTamano ([long]$n * $tamano)) -PercentComplete ([int](100 * $n / $Huellas.Count))
                }
            }
        }
        finally {
            $flujo.Dispose()
        }
    }
    $sha.Dispose()
    Write-Progress -Activity 'Leyendo datos de prueba' -Completed
    # Bloques que ni siquiera se pudieron leer también cuentan como fallo.
    if ($n -lt $Huellas.Count -and $primerFallo -lt 0) {
        $primerFallo = [long]$n * $tamano
    }
    return @{ Verificados = $verificados; PrimerFallo = $primerFallo }
}

# Reglas de inspección: carga de reglas.json, análisis de nombres y de contenido, y recorrido.
# Solo lee ficheros, así que se prueba entero en Linux con fixtures generados.

function Import-AduanaReglas {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    if (-not (Test-Path -LiteralPath $Ruta -PathType Leaf)) {
        throw (New-AduanaError "No encuentro el fichero de reglas en $Ruta.")
    }
    $json = [IO.File]::ReadAllText($Ruta, [Text.Encoding]::UTF8) | ConvertFrom-Json
    $ignorar = [StringComparer]::OrdinalIgnoreCase

    $extensiones = New-Object 'System.Collections.Generic.Dictionary[string,object]' $ignorar
    foreach ($e in $json.extensiones) {
        $extensiones[$e.ext] = @{ Nivel = [string]$e.nivel; Motivo = [string]$e.motivo }
    }
    $documento = New-Object 'System.Collections.Generic.HashSet[string]' $ignorar
    foreach ($e in $json.extensionesDocumento) { [void]$documento.Add($e) }
    $office = New-Object 'System.Collections.Generic.HashSet[string]' $ignorar
    foreach ($e in $json.extensionesOffice) { [void]$office.Add($e) }
    $artefactos = New-Object 'System.Collections.Generic.HashSet[string]' $ignorar
    foreach ($e in $json.artefactosSistema) { [void]$artefactos.Add($e) }

    # Clave entera (el código del carácter) y valor con el tipo de truco que representa.
    $caracteres = @{}
    foreach ($h in $json.caracteres.bidi) { $caracteres[[Convert]::ToInt32($h, 16)] = 'bidi' }
    foreach ($h in $json.caracteres.invisibles) { $caracteres[[Convert]::ToInt32($h, 16)] = 'invisible' }
    foreach ($h in $json.caracteres.puntosFalsos) { $caracteres[[Convert]::ToInt32($h, 16)] = 'punto' }

    $firmas = New-Object 'System.Collections.Generic.List[object]'
    foreach ($f in $json.firmasEjecutables) {
        $hex = ([string]$f.hex).ToLowerInvariant()
        $bytes = New-Object byte[] ($hex.Length / 2)
        for ($i = 0; $i -lt $bytes.Length; $i++) {
            $bytes[$i] = [Convert]::ToByte($hex.Substring($i * 2, 2), 16)
        }
        $firmas.Add(@{ Hex = $hex; Bytes = $bytes; Tipo = [string]$f.tipo })
    }

    return @{
        Extensiones = $extensiones
        Documento   = $documento
        Office      = $office
        Artefactos  = $artefactos
        Prefijos    = @($json.prefijosArtefacto)
        Caracteres  = $caracteres
        Firmas      = $firmas
    }
}

# Identificador de la regla de extensión, en femenino como la palabra «extensión».
function Get-AduanaReglaExtension {
    param([string]$Nivel)
    if ($Nivel -eq 'peligroso') { return 'extension-peligrosa' }
    if ($Nivel -eq 'sospechoso') { return 'extension-sospechosa' }
    return 'extension-informativa'
}

# Paquetes de macOS, que son carpetas pero se abren como una aplicación o un documento.
function Get-AduanaExtensionesPaquete {
    return @('app', 'prefpane', 'kext', 'plugin', 'bundle', 'workflow', 'action', 'scptd')
}

function Get-AduanaExtension {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Nombre)
    $i = $Nombre.LastIndexOf('.')
    if ($i -le 0 -or $i -eq $Nombre.Length - 1) {
        return ''
    }
    return $Nombre.Substring($i + 1).Trim().ToLowerInvariant()
}

function Get-AduanaPenultimaExtension {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Nombre)
    $i = $Nombre.LastIndexOf('.')
    if ($i -le 0) {
        return ''
    }
    return (Get-AduanaExtension -Nombre $Nombre.Substring(0, $i).TrimEnd())
}

function Get-AduanaFirma {
    param([byte[]]$Cabecera, $Reglas)
    if ($null -eq $Cabecera) {
        return $null
    }
    foreach ($firma in $Reglas.Firmas) {
        $b = $firma.Bytes
        if ($Cabecera.Length -lt $b.Length) {
            continue
        }
        $coincide = $true
        for ($i = 0; $i -lt $b.Length; $i++) {
            if ($Cabecera[$i] -ne $b[$i]) {
                $coincide = $false
                break
            }
        }
        if ($coincide) {
            return $firma
        }
    }
    return $null
}

function Read-AduanaCabecera {
    param([Parameter(Mandatory = $true)][string]$Ruta, [int]$Bytes = 8)
    try {
        $flujo = New-Object IO.FileStream($Ruta, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $buffer = New-Object byte[] $Bytes
            $leidos = $flujo.Read($buffer, 0, $Bytes)
            if ($leidos -lt $Bytes) {
                $recorte = New-Object byte[] $leidos
                [Array]::Copy($buffer, $recorte, $leidos)
                return , $recorte
            }
            return , $buffer
        }
        finally {
            $flujo.Dispose()
        }
    }
    catch {
        return $null
    }
}

function Read-AduanaBytes {
    param([Parameter(Mandatory = $true)][string]$Ruta, [long]$Maximo = 64MB)
    $flujo = New-Object IO.FileStream($Ruta, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $tamano = [long][Math]::Min($flujo.Length, $Maximo)
        $buffer = New-Object byte[] $tamano
        $total = 0
        while ($total -lt $tamano) {
            $n = $flujo.Read($buffer, $total, $tamano - $total)
            if ($n -le 0) { break }
            $total += $n
        }
        return , $buffer
    }
    finally {
        $flujo.Dispose()
    }
}

function Test-AduanaArtefacto {
    param(
        [Parameter(Mandatory = $true)][string]$Nombre,
        [Parameter(Mandatory = $true)]$Reglas,
        [bool]$EsDirectorio = $false,
        [byte[]]$Cabecera = $null
    )
    if ($Reglas.Artefactos.Contains($Nombre)) {
        return $true
    }
    foreach ($prefijo in $Reglas.Prefijos) {
        if ($Nombre.StartsWith($prefijo, [StringComparison]::Ordinal)) {
            # Un AppleDouble de verdad empieza por 00 05 16 07. Sin esa firma no es basura de macOS
            # sino un fichero cualquiera que se esconde tras el prefijo, y se analiza como tal.
            if ($EsDirectorio -or $null -eq $Cabecera -or $Cabecera.Length -lt 4) {
                return $false
            }
            return ($Cabecera[0] -eq 0 -and $Cabecera[1] -eq 5 -and $Cabecera[2] -eq 0x16 -and $Cabecera[3] -eq 7)
        }
    }
    return $false
}

function New-AduanaHallazgo {
    param([string]$Nivel, [string]$Regla, [string]$Ruta, [string]$Detalle)
    # El orden de las claves es parte del contrato del JSON.
    return [ordered]@{ nivel = $Nivel; regla = $Regla; ruta = $Ruta; detalle = $Detalle }
}

# Hallazgos que dependen solo del nombre. Devuelve una lista de @{ Nivel; Regla; Detalle }.
function Get-AduanaHallazgosNombre {
    param(
        [Parameter(Mandatory = $true)][string]$Nombre,
        [Parameter(Mandatory = $true)]$Reglas,
        [bool]$EsDirectorio = $false,
        [bool]$EnRaiz = $false,
        $DirectoriosOcultos = $null
    )
    $hallazgos = New-Object 'System.Collections.Generic.List[object]'

    $bidi = New-Object 'System.Collections.Generic.List[string]'
    $invisibles = New-Object 'System.Collections.Generic.List[string]'
    $puntos = New-Object 'System.Collections.Generic.List[string]'
    foreach ($c in $Nombre.ToCharArray()) {
        $n = [int]$c
        if ($Reglas.Caracteres.ContainsKey($n)) {
            $codigo = 'U+' + $n.ToString('X4')
            switch ($Reglas.Caracteres[$n]) {
                'bidi' { if (-not $bidi.Contains($codigo)) { $bidi.Add($codigo) } }
                'invisible' { if (-not $invisibles.Contains($codigo)) { $invisibles.Add($codigo) } }
                'punto' { if (-not $puntos.Contains($codigo)) { $puntos.Add($codigo) } }
            }
        }
    }
    if ($bidi.Count -gt 0) {
        $hallazgos.Add(@{ Nivel = 'peligroso'; Regla = 'caracter-bidi'; Detalle = "El nombre lleva caracteres que cambian el sentido del texto ($($bidi -join ', ')), un truco para disfrazar la extensión." })
    }
    if ($invisibles.Count -gt 0) {
        $hallazgos.Add(@{ Nivel = 'sospechoso'; Regla = 'caracter-invisible'; Detalle = "El nombre lleva caracteres invisibles ($($invisibles -join ', '))." })
    }
    if ($puntos.Count -gt 0) {
        $hallazgos.Add(@{ Nivel = 'peligroso'; Regla = 'punto-falso'; Detalle = "El nombre usa un carácter que imita un punto ($($puntos -join ', ')), así que la extensión que ves no es la real." })
    }

    $ext = Get-AduanaExtension -Nombre $Nombre
    $minusculas = $Nombre.ToLowerInvariant()
    if ($EsDirectorio) {
        if ((Get-AduanaExtensionesPaquete) -contains $ext -and $Reglas.Extensiones.ContainsKey($ext)) {
            $info = $Reglas.Extensiones[$ext]
            $hallazgos.Add(@{ Nivel = $info.Nivel; Regla = (Get-AduanaReglaExtension $info.Nivel); Detalle = "$($info.Motivo)." })
        }
    }
    elseif ($minusculas -eq 'autorun.inf') {
        $nivel = 'sospechoso'
        if ($EnRaiz) { $nivel = 'peligroso' }
        $hallazgos.Add(@{ Nivel = $nivel; Regla = 'autorun'; Detalle = 'Fichero de arranque automático. Windows ya no lo ejecuta, pero su presencia delata un pendrive preparado para engañar o infectado por un gusano antiguo.' })
    }
    elseif ($minusculas -ne 'desktop.ini' -and $Reglas.Extensiones.ContainsKey($ext)) {
        $info = $Reglas.Extensiones[$ext]
        $base = $Nombre.Substring(0, $Nombre.LastIndexOf('.'))
        if ($ext -eq 'lnk' -and $null -ne $DirectoriosOcultos -and $DirectoriosOcultos.Contains($base)) {
            $hallazgos.Add(@{ Nivel = 'peligroso'; Regla = 'carpeta-suplantada'; Detalle = 'Acceso directo con el nombre de una carpeta oculta que está a su lado. Es el truco de los gusanos de USB, que al abrir la supuesta carpeta ejecutan un programa.' })
        }
        elseif ($Nombre -match '\s{3,}') {
            $hallazgos.Add(@{ Nivel = 'peligroso'; Regla = 'extension-camuflada'; Detalle = "La extensión real (.$ext) está escondida detrás de varios espacios. $($info.Motivo)." })
        }
        elseif ($info.Nivel -eq 'peligroso' -and $Reglas.Documento.Contains((Get-AduanaPenultimaExtension -Nombre $Nombre))) {
            $penultima = Get-AduanaPenultimaExtension -Nombre $Nombre
            $hallazgos.Add(@{ Nivel = 'peligroso'; Regla = 'doble-extension'; Detalle = "Parece un fichero .$penultima, pero es .$ext. $($info.Motivo)." })
        }
        else {
            $hallazgos.Add(@{ Nivel = $info.Nivel; Regla = (Get-AduanaReglaExtension $info.Nivel); Detalle = "$($info.Motivo)." })
        }
    }
    return , $hallazgos
}

function Initialize-AduanaCompresion {
    # PowerShell 5.1 no carga por defecto las clases de zip de .NET Framework.
    try {
        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    }
    catch {
        Write-Verbose 'Las clases de zip ya estaban cargadas o las trae el runtime.'
    }
}

function Test-AduanaMacros {
    param([Parameter(Mandatory = $true)][string]$Ruta, [byte[]]$Cabecera)
    if ($null -eq $Cabecera -or $Cabecera.Length -lt 4) {
        return $false
    }
    # Zip (Office moderno): las macros viajan en una entrada vbaProject.bin.
    if ($Cabecera[0] -eq 0x50 -and $Cabecera[1] -eq 0x4b -and $Cabecera[2] -eq 3 -and $Cabecera[3] -eq 4) {
        Initialize-AduanaCompresion
        try {
            $zip = [IO.Compression.ZipFile]::OpenRead($Ruta)
            try {
                foreach ($entrada in $zip.Entries) {
                    if ($entrada.FullName.EndsWith('vbaProject.bin', [StringComparison]::OrdinalIgnoreCase)) {
                        return $true
                    }
                }
            }
            finally {
                $zip.Dispose()
            }
        }
        catch {
            return $false
        }
        return $false
    }
    # OLE (Office antiguo): el proyecto VBA es un flujo llamado _VBA_PROJECT, con el nombre en UTF-16LE.
    if ($Cabecera.Length -ge 8 -and $Cabecera[0] -eq 0xd0 -and $Cabecera[1] -eq 0xcf -and $Cabecera[2] -eq 0x11 -and $Cabecera[3] -eq 0xe0 -and
        $Cabecera[4] -eq 0xa1 -and $Cabecera[5] -eq 0xb1 -and $Cabecera[6] -eq 0x1a -and $Cabecera[7] -eq 0xe1) {
        try {
            $bytes = Read-AduanaBytes -Ruta $Ruta -Maximo 64MB
        }
        catch {
            return $false
        }
        # Latin-1 convierte cada byte en un carácter, así que buscar texto equivale a buscar bytes.
        $texto = [Text.Encoding]::GetEncoding(28591).GetString($bytes)
        $ascii = '_VBA_PROJECT'
        $utf16 = -join ($ascii.ToCharArray() | ForEach-Object { "$_" + [char]0 })
        return ($texto.IndexOf($ascii, [StringComparison]::Ordinal) -ge 0 -or $texto.IndexOf($utf16, [StringComparison]::Ordinal) -ge 0)
    }
    return $false
}

# Hallazgos que dependen del contenido. Devuelve una lista de @{ Nivel; Regla; Detalle }.
function Get-AduanaHallazgosContenido {
    param(
        [Parameter(Mandatory = $true)][string]$Ruta,
        [Parameter(Mandatory = $true)][string]$Nombre,
        [byte[]]$Cabecera,
        [Parameter(Mandatory = $true)]$Reglas
    )
    $hallazgos = New-Object 'System.Collections.Generic.List[object]'
    $ext = Get-AduanaExtension -Nombre $Nombre

    if ($Nombre.ToLowerInvariant() -eq 'desktop.ini') {
        $texto = ''
        try {
            $texto = [Text.Encoding]::GetEncoding(28591).GetString((Read-AduanaBytes -Ruta $Ruta -Maximo 64KB))
            # desktop.ini suele ir en UTF-16LE; quitar los nulos deja el texto legible en ambos casos.
            $texto = $texto.Replace([string][char]0, '')
        }
        catch {
            Write-Verbose "No se pudo leer $Ruta."
        }
        if ($texto -match 'CLSID') {
            $hallazgos.Add(@{ Nivel = 'sospechoso'; Regla = 'desktop-ini'; Detalle = 'Configuración de carpeta que la asocia a un componente del sistema (CLSID), una técnica para que abrir la carpeta ejecute otra cosa.' })
        }
        else {
            $hallazgos.Add(@{ Nivel = 'informativo'; Regla = 'artefacto-sistema'; Detalle = 'Configuración de carpeta que crea Windows.' })
        }
        return , $hallazgos
    }

    $info = $null
    if ($Reglas.Extensiones.ContainsKey($ext)) {
        $info = $Reglas.Extensiones[$ext]
    }
    $marcadaPorExtension = ($null -ne $info -and ($info.Nivel -eq 'peligroso' -or $info.Nivel -eq 'sospechoso'))
    $firma = Get-AduanaFirma -Cabecera $Cabecera -Reglas $Reglas
    if ($null -ne $firma) {
        if ($firma.Hex -ne '2321' -and -not $marcadaPorExtension) {
            $hallazgos.Add(@{ Nivel = 'peligroso'; Regla = 'contenido-ejecutable'; Detalle = "Por dentro es un $($firma.Tipo), aunque su extensión no lo diga." })
        }
        elseif ($firma.Hex -eq '2321' -and $ext -eq '') {
            $hallazgos.Add(@{ Nivel = 'peligroso'; Regla = 'script-sin-extension'; Detalle = 'Script sin extensión. macOS lo ejecuta en Terminal con doble clic en pendrives FAT y exFAT.' })
        }
    }
    if ($Reglas.Office.Contains($ext) -and -not ($null -ne $info -and $info.Nivel -eq 'peligroso')) {
        if (Test-AduanaMacros -Ruta $Ruta -Cabecera $Cabecera) {
            $hallazgos.Add(@{ Nivel = 'peligroso'; Regla = 'macros'; Detalle = 'Documento con macros, aunque su extensión no lo diga.' })
        }
    }
    return , $hallazgos
}

function Test-AduanaOculto {
    param([Parameter(Mandatory = $true)][IO.FileSystemInfo]$Info)
    return (($Info.Attributes -band [IO.FileAttributes]::Hidden) -ne 0 -or $Info.Name.StartsWith('.'))
}

function Test-AduanaEnlace {
    param([Parameter(Mandatory = $true)][IO.FileSystemInfo]$Info)
    return (($Info.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0)
}

function Get-AduanaOrdenNivel {
    param([string]$Nivel)
    switch ($Nivel) {
        'peligroso' { return 0 }
        'sospechoso' { return 1 }
        default { return 2 }
    }
}

function Get-AduanaHallazgosOrdenados {
    param([Parameter(Mandatory = $true)][AllowEmptyCollection()]$Hallazgos)
    $lista = New-Object 'System.Collections.Generic.List[object]'
    foreach ($h in $Hallazgos) { $lista.Add($h) }
    $comparar = [Comparison[object]] {
        param($a, $b)
        $d = (Get-AduanaOrdenNivel $a.nivel) - (Get-AduanaOrdenNivel $b.nivel)
        if ($d -ne 0) { return $d }
        $d = [string]::CompareOrdinal($a.ruta, $b.ruta)
        if ($d -ne 0) { return $d }
        return [string]::CompareOrdinal($a.regla, $b.regla)
    }
    $lista.Sort($comparar)
    return , $lista
}

function Get-AduanaResumen {
    param($Hallazgos, [int]$Ficheros, [int]$Carpetas)
    $resumen = [ordered]@{ ficheros = $Ficheros; carpetas = $Carpetas; peligroso = 0; sospechoso = 0; informativo = 0 }
    foreach ($h in $Hallazgos) {
        $resumen[$h.nivel] = $resumen[$h.nivel] + 1
    }
    return $resumen
}

function Get-AduanaVeredicto {
    param($Resumen)
    if ($Resumen.peligroso -gt 0) { return @{ Veredicto = 'peligroso'; Codigo = 2 } }
    if ($Resumen.sospechoso -gt 0) { return @{ Veredicto = 'sospechoso'; Codigo = 1 } }
    return @{ Veredicto = 'limpio'; Codigo = 0 }
}

# Recorrido completo de una ruta. No sigue enlaces, no entra en artefactos ni en paquetes de
# macOS, y se detiene en los límites de profundidad y de número de entradas.
function Invoke-AduanaRecorrido {
    param(
        [Parameter(Mandatory = $true)][string]$Raiz,
        [Parameter(Mandatory = $true)]$Reglas,
        [int]$ProfundidadMaxima = 32,
        [int]$EntradasMaximas = 100000
    )
    $raizCompleta = [IO.Path]::GetFullPath($Raiz)
    $raizInfo = New-Object IO.DirectoryInfo $raizCompleta
    if (-not $raizInfo.Exists) {
        throw (New-AduanaError "No existe la carpeta $Raiz.")
    }
    $hallazgos = New-Object 'System.Collections.Generic.List[object]'
    $entradas = New-Object 'System.Collections.Generic.List[object]'
    $ficheros = 0
    $carpetas = 0
    $total = 0
    $paquetes = Get-AduanaExtensionesPaquete
    $pila = New-Object 'System.Collections.Generic.Stack[object]'
    $pila.Push(@{ Info = $raizInfo; Profundidad = 0; Rel = '' })
    $detenido = $false

    while ($pila.Count -gt 0 -and -not $detenido) {
        $actual = $pila.Pop()
        $relActual = $actual.Rel
        if (-not $relActual) { $relActual = '.' }
        try {
            $hijos = @($actual.Info.EnumerateFileSystemInfos())
        }
        catch {
            $hallazgos.Add((New-AduanaHallazgo 'informativo' 'sin-acceso' $relActual 'No se ha podido leer esta carpeta, así que su contenido queda sin revisar.'))
            continue
        }
        $ocultos = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($h in $hijos) {
            if ($h -is [IO.DirectoryInfo] -and (Test-AduanaOculto -Info $h)) {
                [void]$ocultos.Add($h.Name)
            }
        }
        foreach ($h in $hijos) {
            $total++
            if ($total -gt $EntradasMaximas) {
                $hallazgos.Add((New-AduanaHallazgo 'informativo' 'limite-alcanzado' $relActual "Hay más de $EntradasMaximas entradas. Aduana deja de recorrer aquí y el resto queda sin revisar."))
                $detenido = $true
                break
            }
            if ($actual.Rel) { $rel = $actual.Rel + '/' + $h.Name } else { $rel = $h.Name }
            $esDirectorio = $h -is [IO.DirectoryInfo]
            $entrada = @{
                Rel = $rel; Completa = $h.FullName; Nombre = $h.Name; EsDirectorio = $esDirectorio
                Oculto = (Test-AduanaOculto -Info $h); Enlace = (Test-AduanaEnlace -Info $h)
                Artefacto = $false; Firma = $null; Peligroso = $false; Paquete = $false
            }
            $entradas.Add($entrada)

            if ($entrada.Enlace) {
                $hallazgos.Add((New-AduanaHallazgo 'sospechoso' 'enlace-simbolico' $rel 'Enlace simbólico o punto de unión. Puede apuntar fuera del pendrive, así que Aduana no lo sigue.'))
                continue
            }
            if ($esDirectorio) { $carpetas++ } else { $ficheros++ }

            $cabecera = $null
            if (-not $esDirectorio) {
                $cabecera = Read-AduanaCabecera -Ruta $h.FullName
            }
            if (Test-AduanaArtefacto -Nombre $h.Name -Reglas $Reglas -EsDirectorio $esDirectorio -Cabecera $cabecera) {
                $entrada.Artefacto = $true
                $hallazgos.Add((New-AduanaHallazgo 'informativo' 'artefacto-sistema' $rel 'Lo crea el sistema operativo por su cuenta.'))
                continue
            }

            $propios = New-Object 'System.Collections.Generic.List[object]'
            foreach ($x in (Get-AduanaHallazgosNombre -Nombre $h.Name -Reglas $Reglas -EsDirectorio $esDirectorio -EnRaiz ($actual.Profundidad -eq 0) -DirectoriosOcultos $ocultos)) {
                $propios.Add($x)
            }
            if (-not $esDirectorio) {
                foreach ($x in (Get-AduanaHallazgosContenido -Ruta $h.FullName -Nombre $h.Name -Cabecera $cabecera -Reglas $Reglas)) {
                    $propios.Add($x)
                }
                $firma = Get-AduanaFirma -Cabecera $cabecera -Reglas $Reglas
                if ($null -ne $firma) { $entrada.Firma = $firma.Tipo }
            }
            $esArtefacto = $false
            foreach ($x in $propios) {
                if ($x.Regla -eq 'artefacto-sistema') { $esArtefacto = $true }
                if ($x.Nivel -eq 'peligroso') { $entrada.Peligroso = $true }
                $hallazgos.Add((New-AduanaHallazgo $x.Nivel $x.Regla $rel $x.Detalle))
            }
            $entrada.Artefacto = $esArtefacto
            if ($entrada.Oculto -and -not $esArtefacto) {
                $hallazgos.Add((New-AduanaHallazgo 'informativo' 'oculto' $rel 'Entrada oculta.'))
            }

            if ($esDirectorio) {
                if ($paquetes -contains (Get-AduanaExtension -Nombre $h.Name)) {
                    $entrada.Paquete = $true
                }
                elseif ($actual.Profundidad + 1 -gt $ProfundidadMaxima) {
                    $hallazgos.Add((New-AduanaHallazgo 'informativo' 'limite-alcanzado' $rel "La carpeta está a más de $ProfundidadMaxima niveles de profundidad y su contenido queda sin revisar."))
                }
                else {
                    $pila.Push(@{ Info = $h; Profundidad = $actual.Profundidad + 1; Rel = $rel })
                }
            }
        }
    }
    return @{ Raiz = $raizCompleta; Hallazgos = $hallazgos; Entradas = $entradas; Ficheros = $ficheros; Carpetas = $carpetas }
}

# Hallazgos del dispositivo a partir de lo que devuelve la capa de sistema.
function Get-AduanaHallazgosDispositivo {
    param($Interfaces, $ParticionesOcultas)
    $hallazgos = New-Object 'System.Collections.Generic.List[object]'
    $hid = @(); $red = @(); $cd = @()
    foreach ($i in @($Interfaces)) {
        if ($null -eq $i) { continue }
        switch ($i.Clase) {
            { $_ -in 'Keyboard', 'HIDClass', 'Mouse' } { $hid += $i.Nombre }
            'Net' { $red += $i.Nombre }
            'CDROM' { $cd += $i.Nombre }
        }
    }
    if ($hid.Count -gt 0) {
        $hallazgos.Add((New-AduanaHallazgo 'peligroso' 'dispositivo-hid' '.' "El pendrive se presenta también como teclado o dispositivo de entrada ($($hid -join ', ')). Es la huella de un BadUSB, desconéctalo."))
    }
    if ($red.Count -gt 0) {
        $hallazgos.Add((New-AduanaHallazgo 'sospechoso' 'dispositivo-red' '.' "El pendrive se presenta también como tarjeta de red ($($red -join ', ')), algo que un pendrive normal no hace."))
    }
    if ($cd.Count -gt 0) {
        $hallazgos.Add((New-AduanaHallazgo 'sospechoso' 'unidad-cd-virtual' '.' "El pendrive incluye una unidad de CD virtual ($($cd -join ', ')). Algunos fabricantes la usan para su software, pero también sirve para colar programas."))
    }
    foreach ($p in @($ParticionesOcultas)) {
        if ($null -eq $p) { continue }
        $hallazgos.Add((New-AduanaHallazgo 'sospechoso' 'particion-oculta' '.' "Partición sin letra asignada ($p), cuyo contenido no se ha revisado."))
    }
    return , $hallazgos
}

function Get-AduanaNivelVirusTotal {
    param([int]$Maliciosos)
    if ($Maliciosos -ge 3) { return 'peligroso' }
    if ($Maliciosos -ge 1) { return 'sospechoso' }
    return $null
}

# Salida de MpCmdRun con amenazas: bloques «Threat : nombre» seguidos de «file : ruta».
function ConvertFrom-AduanaSalidaDefender {
    param([AllowEmptyString()][string]$Salida, [int]$Codigo)
    $detecciones = New-Object 'System.Collections.Generic.List[object]'
    $amenaza = $null
    foreach ($linea in ($Salida -split "`r?`n")) {
        if ($linea -match '^\s*Threat\s*:\s*(.+?)\s*$') {
            $amenaza = $Matches[1]
        }
        elseif ($linea -match '^\s*file\s*:\s*(.+?)\s*$' -and $null -ne $amenaza) {
            $detecciones.Add(@{ Amenaza = $amenaza; Fichero = $Matches[1] })
        }
    }
    if ($Codigo -eq 0 -and $detecciones.Count -eq 0) {
        return @{ Estado = 'limpio'; Detecciones = $detecciones }
    }
    if ($Codigo -eq 2 -or $detecciones.Count -gt 0) {
        return @{ Estado = 'detecciones'; Detecciones = $detecciones }
    }
    return @{ Estado = 'error'; Detecciones = $detecciones }
}

function Get-AduanaIdTeclado {
    param([AllowEmptyString()][AllowNull()][string]$Texto)
    if ($Texto -match 'VID_([0-9A-Fa-f]{4})&PID_([0-9A-Fa-f]{4})') {
        return ('VID_{0}&PID_{1}' -f $Matches[1].ToUpperInvariant(), $Matches[2].ToUpperInvariant())
    }
    return $null
}

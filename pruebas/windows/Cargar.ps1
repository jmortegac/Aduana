# Carga el código de Aduana para Windows en el ámbito de las pruebas y ofrece constructores de
# fixtures. Todos los fixtures se generan en la prueba; nunca hay binarios maliciosos en el repo.

Set-StrictMode -Version 2
$RaizRepo = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$libAduana = Join-Path (Join-Path $RaizRepo 'windows') 'lib'
foreach ($parte in @('Comun', 'Reglas', 'Manifiesto', 'Salida', 'Sistema', 'Centinela', 'Ordenes')) {
    . (Join-Path $libAduana "$parte.ps1")
}
$Reglas = Import-AduanaReglas -Ruta (Join-Path (Join-Path $RaizRepo 'reglas') 'reglas.json')

# Caracteres de engaño, siempre por su código para no dejarlos crudos en el fuente.
$RLO = [string][char]0x202E
$PuntoFalso = [string][char]0x2024
$EspacioCero = [string][char]0x200B

function Write-FixtureBytes {
    param([string]$Ruta, [byte[]]$Bytes)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Ruta))
    [IO.File]::WriteAllBytes($Ruta, $Bytes)
}

function Write-FixtureTexto {
    param([string]$Ruta, [string]$Texto)
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Ruta))
    [IO.File]::WriteAllText($Ruta, $Texto, (New-Object Text.UTF8Encoding $false))
}

function New-FixtureZip {
    param([string]$Ruta, [hashtable]$Entradas)
    Initialize-AduanaCompresion
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Ruta))
    $zip = [IO.Compression.ZipFile]::Open($Ruta, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($nombre in $Entradas.Keys) {
            $e = $zip.CreateEntry($nombre)
            $w = New-Object IO.StreamWriter($e.Open(), (New-Object Text.UTF8Encoding $false))
            try { $w.Write([string]$Entradas[$nombre]) } finally { $w.Dispose() }
        }
    }
    finally {
        $zip.Dispose()
    }
}

function Get-BytesMz { return [byte[]](@(0x4d, 0x5a, 0x90, 0x00) + @(0) * 60) }

function Get-BytesOleConMacros {
    $cabecera = [byte[]]@(0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1)
    $relleno = [byte[]](@(0) * 504)
    $nombre = [Text.Encoding]::Unicode.GetBytes('_VBA_PROJECT')
    return [byte[]]($cabecera + $relleno + $nombre + [byte[]](@(0) * 64))
}

# JPEG mínimo con un bloque EXIF cuyo directorio GPS trae latitud (etiqueta 2).
function Get-BytesJpegConGps {
    param([switch]$SinGps)
    $tiff = New-Object 'System.Collections.Generic.List[byte]'
    $tiff.AddRange([byte[]]@(0x49, 0x49, 0x2a, 0x00, 0x08, 0x00, 0x00, 0x00))
    # IFD0 con una entrada: 0x8825 (puntero GPS) o 0x010f (fabricante) si no se quiere GPS.
    $tiff.AddRange([byte[]]@(0x01, 0x00))
    if ($SinGps) {
        $tiff.AddRange([byte[]]@(0x0f, 0x01, 0x02, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
    }
    else {
        $tiff.AddRange([byte[]]@(0x25, 0x88, 0x04, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1a, 0x00, 0x00, 0x00))
    }
    $tiff.AddRange([byte[]]@(0x00, 0x00, 0x00, 0x00))
    # IFD GPS en el desplazamiento 26 con la etiqueta 2 (latitud).
    $tiff.AddRange([byte[]]@(0x01, 0x00, 0x02, 0x00, 0x05, 0x00, 0x03, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00))
    $tiff.AddRange([byte[]](@(0) * 24))
    $exif = [byte[]](@(0x45, 0x78, 0x69, 0x66, 0x00, 0x00) + $tiff.ToArray())
    $largo = $exif.Length + 2
    $app1 = [byte[]](@(0xff, 0xe1, [byte]($largo -shr 8), [byte]($largo -band 0xff)) + $exif)
    return [byte[]](@(0xff, 0xd8) + $app1 + @(0xff, 0xd9))
}

# Pendrive de pruebas con un caso de cada regla y un fichero limpio de control.
function New-FixturePendrive {
    param([Parameter(Mandatory = $true)][string]$Raiz)
    [void][IO.Directory]::CreateDirectory($Raiz)
    Write-FixtureBytes (Join-Path $Raiz 'factura.pdf.exe') (Get-BytesMz)
    Write-FixtureBytes (Join-Path $Raiz 'factura.pdf     .exe') (Get-BytesMz)
    Write-FixtureBytes (Join-Path $Raiz ("foto$($RLO)gpj.exe")) (Get-BytesMz)
    Write-FixtureTexto (Join-Path $Raiz ("informe$($PuntoFalso)pdf")) 'texto'
    Write-FixtureTexto (Join-Path $Raiz ("fac$($EspacioCero)tura.txt")) 'texto'
    Write-FixtureTexto (Join-Path $Raiz 'autorun.inf') "[autorun]`r`nopen=x.exe`r`n"
    Write-FixtureTexto (Join-Path (Join-Path $Raiz 'sub') 'autorun.inf') "[autorun]`r`n"
    Write-FixtureTexto (Join-Path $Raiz 'desktop.ini') "[.ShellClassInfo]`r`nCLSID={645FF040-5081-101B-9F08-00AA002F954E}`r`n"
    Write-FixtureTexto (Join-Path $Raiz 'carta.docm') 'no importa'
    Write-FixtureBytes (Join-Path $Raiz 'viejo.doc') (Get-BytesOleConMacros)
    New-FixtureZip (Join-Path $Raiz 'trampa.docx') @{ '[Content_Types].xml' = '<Types/>'; 'word/document.xml' = '<w/>'; 'word/vbaProject.bin' = 'vba' }
    Write-FixtureBytes (Join-Path $Raiz 'foto.jpg') (Get-BytesMz)
    Write-FixtureTexto (Join-Path $Raiz 'instalar') "#!/bin/sh`necho hola`n"
    Write-FixtureTexto (Join-Path $Raiz '.DS_Store') 'basura'
    Write-FixtureBytes (Join-Path $Raiz '._x') ([byte[]]@(0x00, 0x05, 0x16, 0x07, 0x00, 0x02, 0x00, 0x00))
    Write-FixtureBytes (Join-Path $Raiz '._trampa.exe') (Get-BytesMz)
    Write-FixtureTexto (Join-Path $Raiz '.oculto.txt') 'texto'
    Write-FixtureTexto (Join-Path $Raiz 'notas.txt') 'Un fichero normal y corriente.'
    Write-FixtureBytes (Join-Path (Join-Path $Raiz 'Fotos') 'vacaciones.jpg') ([byte[]]@(0xff, 0xd8, 0xff, 0xe0, 0, 0))
    Write-FixtureBytes (Join-Path (Join-Path (Join-Path (Join-Path $Raiz 'Programa.app') 'Contents') 'MacOS') 'Programa') ([byte[]]@(0xcf, 0xfa, 0xed, 0xfe))
    Write-FixtureTexto (Join-Path $Raiz 'pagina.html') '<html></html>'
    # El enlace apunta a una carpeta hermana del volumen. Apuntar a un antepasado, como el
    # directorio temporal, crea un bucle que rompe la limpieza de Pester en Windows.
    $fuera = Join-Path (Split-Path -Path $Raiz -Parent) ('fuera-' + [Guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $fuera
    $null = New-Item -ItemType SymbolicLink -Path (Join-Path $Raiz 'enlace') -Target $fuera
}

# Deja una clave privada legible por cualquiera. En Windows, OpenSSH mira las ACL y no los bits de
# modo, así que se concede lectura a Todos con icacls, por su SID para no depender del idioma.
function Open-FixtureClaveAOtros {
    param([string]$Ruta)
    if ($env:OS -eq 'Windows_NT') {
        $null = & icacls $Ruta /grant '*S-1-1-0:R'
    }
    else {
        & chmod 644 $Ruta
    }
}

# Pares «ruta|regla» de una lista de hallazgos, para comparar con lo esperado.
function Get-ParesHallazgos {
    param($Hallazgos)
    return @($Hallazgos | ForEach-Object { "$($_.ruta)|$($_.regla)" })
}

function Get-PwshActual {
    return (Get-Process -Id $PID).Path
}

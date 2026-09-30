# Pruebas de integración de Aduana en Windows real, sin mocks. Pensadas para el runner de GitHub
# (Windows Server, administrador, Windows PowerShell 5.1), no para un equipo personal: tocan el
# registro, crean y formatean un disco virtual y escriben la cadena de prueba EICAR.
#
# Todo lo que cambian lo deshacen al terminar, pero aun así no las lances en tu equipo.
#
# Uso: powershell -ExecutionPolicy Bypass -File pruebas\integracion\windows.ps1

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$repo = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$aduana = Join-Path (Join-Path $repo 'windows') 'Aduana.ps1'
# Se cargan las funciones de Aduana para reutilizar su lista de valores del registro, su búsqueda
# de ssh-keygen y su forma de entrecomillar argumentos. Las órdenes se prueban siempre como proceso.
foreach ($parte in @('Comun', 'Reglas', 'Manifiesto', 'Salida', 'Sistema', 'Centinela', 'Ordenes')) {
    . (Join-Path (Join-Path (Join-Path $repo 'windows') 'lib') "$parte.ps1")
}

$trabajo = Join-Path ([IO.Path]::GetTempPath()) ('aduana-integracion-' + [Guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $trabajo
$env:ADUANA_ESTADO = Join-Path $trabajo 'estado'

$script:Correctas = 0
$script:Fallidas = 0
$script:Omitidas = 0

function Comprobar {
    param([string]$Descripcion, [bool]$Condicion, [string]$Detalle = '')
    if ($Condicion) {
        $script:Correctas++
        Write-Host "ok        $Descripcion"
    }
    else {
        $script:Fallidas++
        Write-Host "FALLO     $Descripcion" -ForegroundColor Red
        if ($Detalle) { Write-Host "          $Detalle" }
        Write-Host "::error::$Descripcion"
    }
}

function Omitir {
    param([string]$Descripcion, [string]$Motivo)
    $script:Omitidas++
    Write-Host "omitida   $Descripcion, $Motivo" -ForegroundColor Yellow
    Write-Host "::warning::$Descripcion, $Motivo"
}

# Lanza Aduana en un proceso nuevo de Windows PowerShell, como lo haría un usuario, y captura la
# salida en UTF-8 para poder leer el JSON con tildes.
function Invoke-AduanaCli {
    param([string[]]$Argumentos)
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = (Get-Command -Name powershell.exe).Source
    $todos = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $aduana) + $Argumentos
    $info.Arguments = (@($todos | ForEach-Object { ConvertTo-AduanaArgumento -Argumento $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = New-Object Text.UTF8Encoding $false
    $info.StandardErrorEncoding = New-Object Text.UTF8Encoding $false
    $info.CreateNoWindow = $true
    $p = [Diagnostics.Process]::Start($info)
    $salida = $p.StandardOutput.ReadToEndAsync()
    $errores = $p.StandardError.ReadToEndAsync()
    $p.WaitForExit()
    $r = @{ Codigo = $p.ExitCode; Salida = $salida.Result; Error = $errores.Result }
    $p.Dispose()
    return $r
}

function ConvertFrom-SalidaJson {
    param($Resultado)
    try { return ($Resultado.Salida | ConvertFrom-Json) } catch { return $null }
}

function Get-Diagnostico {
    param($Resultado)
    return "código $($Resultado.Codigo). stdout: $($Resultado.Salida.Trim()) stderr: $($Resultado.Error.Trim())"
}

function Invoke-Diskpart {
    param([string[]]$Ordenes)
    $guion = Join-Path $trabajo ('diskpart-' + [Guid]::NewGuid().ToString('N') + '.txt')
    [IO.File]::WriteAllLines($guion, $Ordenes)
    $salida = & diskpart.exe /s $guion 2>&1 | Out-String
    Remove-Item -LiteralPath $guion -Force
    return $salida
}

function Get-EstadoAutomontaje {
    $s = Invoke-Diskpart -Ordenes @('automount')
    if ($s -match 'disabled') { return 'desactivado' }
    if ($s -match 'enabled') { return 'activado' }
    return "desconocido: $s"
}

# Foto de los valores y las claves que toca preparar-equipo, para comparar antes y después.
function Get-FotoRegistro {
    $lineas = New-Object 'System.Collections.Generic.List[string]'
    foreach ($o in (Get-AduanaObjetivosEquipo)) {
        $ruta = $o.Ruta
        while ($ruta -and $ruta -notmatch '^HK(CU|LM):\\?$') {
            $lineas.Add("clave $ruta = $(Test-Path -LiteralPath $ruta)")
            $ruta = Split-Path -Path $ruta -Parent
        }
        $valor = '<no existe>'
        if (Test-Path -LiteralPath $o.Ruta) {
            $propiedad = Get-ItemProperty -LiteralPath $o.Ruta -Name $o.Nombre -ErrorAction SilentlyContinue
            if ($null -ne $propiedad) { $valor = [string]$propiedad.($o.Nombre) }
        }
        $lineas.Add("valor $($o.Ruta)\$($o.Nombre) = $valor")
    }
    return (($lineas | Sort-Object -Unique) -join "`n")
}

function New-DocxConAutor {
    param([string]$Ruta)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::Open($Ruta, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $entradas = [ordered]@{
            '[Content_Types].xml' = '<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"/>'
            'word/document.xml' = '<?xml version="1.0" encoding="UTF-8"?><w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"/>'
            'docProps/core.xml' = '<?xml version="1.0" encoding="UTF-8"?><cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>Ana Perez</dc:creator><cp:lastModifiedBy>Ana Perez</cp:lastModifiedBy></cp:coreProperties>'
            'docProps/app.xml' = '<?xml version="1.0" encoding="UTF-8"?><Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Company>Acme Secreta</Company></Properties>'
        }
        foreach ($nombre in $entradas.Keys) {
            $w = New-Object IO.StreamWriter(($zip.CreateEntry($nombre)).Open(), (New-Object Text.UTF8Encoding $false))
            try { $w.Write($entradas[$nombre]) } finally { $w.Dispose() }
        }
    }
    finally { $zip.Dispose() }
}

function Read-EntradaZip {
    param([string]$Ruta, [string]$Entrada)
    $zip = [IO.Compression.ZipFile]::OpenRead($Ruta)
    try {
        $e = $zip.GetEntry($Entrada)
        $r = New-Object IO.StreamReader($e.Open())
        try { return $r.ReadToEnd() } finally { $r.Dispose() }
    }
    finally { $zip.Dispose() }
}

$vhd = Join-Path $trabajo 'pendrive.vhdx'
$discoAdjunto = $false
try {
    Write-Host '== Entorno'
    Write-Host "Windows $([Environment]::OSVersion.Version), PowerShell $($PSVersionTable.PSVersion)"
    Comprobar 'el runner es administrador' (Test-AduanaAdmin)
    $ssh = Find-AduanaSshKeygen
    Comprobar 'Aduana usa el ssh-keygen de Windows' ($ssh -like "$env:WINDIR\System32\OpenSSH\*") "encontrado: $ssh"

    # ------------------------------------------------------------------------------------------
    Write-Host '== Registro y automontaje'
    $fotoAntes = Get-FotoRegistro
    $automontajeAntes = Get-EstadoAutomontaje
    $r = Invoke-AduanaCli -Argumentos @('preparar-equipo', '--sin-automontaje')
    Comprobar 'preparar-equipo devuelve 0' ($r.Codigo -eq 0) (Get-Diagnostico $r)
    foreach ($o in (Get-AduanaObjetivosEquipo)) {
        $valor = $null
        $propiedad = Get-ItemProperty -LiteralPath $o.Ruta -Name $o.Nombre -ErrorAction SilentlyContinue
        if ($null -ne $propiedad) { $valor = $propiedad.($o.Nombre) }
        Comprobar "preparar-equipo pone $($o.Nombre) en $($o.Ruta.Substring(0, 4))" ($valor -eq $o.Valor) "valor: $valor"
    }
    Comprobar 'preparar-equipo desactiva el automontaje' ((Get-EstadoAutomontaje) -eq 'desactivado')
    $r = Invoke-AduanaCli -Argumentos @('restaurar-equipo')
    Comprobar 'restaurar-equipo devuelve 0' ($r.Codigo -eq 0) (Get-Diagnostico $r)
    $fotoDespues = Get-FotoRegistro
    Comprobar 'el registro queda exactamente como estaba' ($fotoDespues -eq $fotoAntes) "antes:`n$fotoAntes`ndespués:`n$fotoDespues"
    Comprobar 'el automontaje queda como estaba' ((Get-EstadoAutomontaje) -eq $automontajeAntes) "antes: $automontajeAntes"

    # ------------------------------------------------------------------------------------------
    Write-Host '== Disco virtual como pendrive'
    $null = Invoke-Diskpart -Ordenes @("create vdisk file=`"$vhd`" maximum=256 type=expandable", "select vdisk file=`"$vhd`"", 'attach vdisk')
    $discoAdjunto = $true
    $numero = (Get-DiskImage -ImagePath $vhd | Get-Disk).Number
    Write-Host "Disco virtual en el número $numero, bus $((Get-Disk -Number $numero).BusType)"

    $sistema = (Get-Disk | Where-Object { $_.IsSystem -or $_.IsBoot } | Select-Object -First 1).Number
    $r = Invoke-AduanaCli -Argumentos @('salida', 'preparar', "$sistema", '--si')
    Comprobar 'salida preparar rechaza el disco del sistema incluso con --si' ($r.Codigo -eq 3) (Get-Diagnostico $r)
    Comprobar 'y el disco del sistema sigue en línea' (-not (Get-Disk -Number $sistema).IsOffline)

    $r = Invoke-AduanaCli -Argumentos @('salida', 'preparar', "$numero", '--si', '--nombre', 'ADUANAPRUEB')
    Comprobar 'salida preparar formatea el disco virtual' ($r.Codigo -eq 0) (Get-Diagnostico $r)
    $volumen = Get-Partition -DiskNumber $numero | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1
    Comprobar 'queda en exFAT con la etiqueta pedida' ($volumen -and $volumen.FileSystem -eq 'exFAT' -and $volumen.FileSystemLabel -eq 'ADUANAPRUEB') "volumen: $($volumen | Out-String)"
    Comprobar 'con tabla MBR' ((Get-Disk -Number $numero).PartitionStyle -eq 'MBR')
    $raiz = "$($volumen.DriveLetter):\"

    # Limpieza de metadatos en un docx de verdad.
    $docx = Join-Path $raiz 'informe.docx'
    New-DocxConAutor -Ruta $docx
    [IO.File]::WriteAllText((Join-Path $raiz 'Thumbs.db'), 'basura')
    $r = Invoke-AduanaCli -Argumentos @('salida', 'limpiar', $raiz)
    Comprobar 'salida limpiar devuelve 0' ($r.Codigo -eq 0) (Get-Diagnostico $r)
    Comprobar 'quita el autor del docx' ((Read-EntradaZip -Ruta $docx -Entrada 'docProps/core.xml') -notmatch 'Ana')
    Comprobar 'quita la empresa del docx' ((Read-EntradaZip -Ruta $docx -Entrada 'docProps/app.xml') -notmatch 'Acme')
    Comprobar 'borra Thumbs.db' (-not (Test-Path -LiteralPath (Join-Path $raiz 'Thumbs.db')))

    # Ficheros trampa, generados aquí.
    $rlo = [string][char]0x202E
    [IO.File]::WriteAllText((Join-Path $raiz 'notas.txt'), 'Un fichero normal.')
    [IO.File]::WriteAllText((Join-Path $raiz 'factura.pdf.exe'), 'no es un programa de verdad')
    [IO.File]::WriteAllBytes((Join-Path $raiz 'foto.jpg'), [byte[]]@(0x4d, 0x5a, 0x90, 0x00))
    [IO.File]::WriteAllText((Join-Path $raiz ("informe" + $rlo + "fdp.exe")), 'x')
    $null = New-Item -ItemType Directory -Path (Join-Path $raiz 'docs')
    [IO.File]::WriteAllText((Join-Path (Join-Path $raiz 'docs') 'uno.txt'), 'uno')

    # Firma con el ssh-keygen de Windows y verificación.
    $clave = Join-Path $trabajo 'clave'
    $k = Invoke-AduanaProceso -Programa $ssh -Argumentos @('-q', '-t', 'ed25519', '-N', '', '-C', 'integracion', '-f', $clave)
    Comprobar 'ssh-keygen de Windows crea la clave de prueba' ($k.Codigo -eq 0 -and (Test-Path -LiteralPath $clave)) $k.Error
    $r = Invoke-AduanaCli -Argumentos @('salida', 'firmar', $raiz, '--clave', $clave)
    Comprobar 'salida firmar devuelve 0' ($r.Codigo -eq 0) (Get-Diagnostico $r)
    $r = Invoke-AduanaCli -Argumentos @('verificar', $raiz, '--json')
    $j = ConvertFrom-SalidaJson $r
    Comprobar 'verificar da firmante desconocido e intacto' ($r.Codigo -eq 1 -and $j -and $j.veredicto -eq 'intacto') (Get-Diagnostico $r)

    # Montaje en solo lectura.
    $r = Invoke-AduanaCli -Argumentos @('montar', "$numero")
    Comprobar 'montar devuelve 0' ($r.Codigo -eq 0) (Get-Diagnostico $r)
    Comprobar 'el disco queda en solo lectura' ((Get-Disk -Number $numero).IsReadOnly)
    $volumen = Get-Partition -DiskNumber $numero | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1
    $raiz = "$($volumen.DriveLetter):\"
    $escrito = $true
    try { [IO.File]::WriteAllText((Join-Path $raiz 'intruso.txt'), 'x') } catch { $escrito = $false }
    Comprobar 'no se puede escribir en el pendrive montado' (-not $escrito)
    $r = Invoke-AduanaCli -Argumentos @('verificar', $raiz)
    Comprobar 'verificar sigue intacto en solo lectura' ($r.Codigo -eq 1) (Get-Diagnostico $r)

    # Inspección.
    $r = Invoke-AduanaCli -Argumentos @('inspeccionar', $raiz, '--json', '--sin-antivirus')
    $j = ConvertFrom-SalidaJson $r
    Comprobar 'inspeccionar devuelve 2' ($r.Codigo -eq 2) (Get-Diagnostico $r)
    $pares = @()
    if ($j) { $pares = @($j.hallazgos | ForEach-Object { "$($_.regla)|$($_.ruta)" }) }
    foreach ($esperado in @('doble-extension|factura.pdf.exe', 'contenido-ejecutable|foto.jpg', ("caracter-bidi|informe" + $rlo + "fdp.exe"))) {
        Comprobar "inspeccionar encuentra $($esperado.Replace($rlo, '<U+202E>'))" ($pares -contains $esperado) ($pares -join ', ')
    }
    Comprobar 'inspeccionar no marca notas.txt' (-not ($pares -match '\|notas\.txt$'))

    # Copia con marca de origen a NTFS.
    $destino = Join-Path $trabajo 'copia'
    # Sin --sin-antivirus, para que la copia pase también por el Defender real.
    $r = Invoke-AduanaCli -Argumentos @('copiar', $raiz, $destino, '--json')
    Comprobar 'copiar devuelve 0' ($r.Codigo -eq 0) (Get-Diagnostico $r)
    $nota = Join-Path $destino 'notas.txt'
    Comprobar 'copia notas.txt' (Test-Path -LiteralPath $nota)
    Comprobar 'no copia factura.pdf.exe' (-not (Test-Path -LiteralPath (Join-Path $destino 'factura.pdf.exe')))
    $zona = ''
    try { $zona = (Get-Content -LiteralPath $nota -Stream 'Zone.Identifier' -ErrorAction Stop) -join "`n" } catch { $zona = "sin flujo: $($_.Exception.Message)" }
    Comprobar 'la copia lleva Zone.Identifier con ZoneId=3' ($zona -match 'ZoneId=3') $zona

    # Capacidad, con el disco otra vez en escritura.
    Set-Disk -Number $numero -IsReadOnly $false
    $volumen = Get-Partition -DiskNumber $numero | Get-Volume | Where-Object { $_.DriveLetter } | Select-Object -First 1
    $raiz = "$($volumen.DriveLetter):\"
    $r = Invoke-AduanaCli -Argumentos @('salida', 'comprobar-capacidad', $raiz, '--limite', '16')
    Comprobar 'comprobar-capacidad devuelve 0 en un disco sano' ($r.Codigo -eq 0) (Get-Diagnostico $r)
    Comprobar 'y no deja sus ficheros' (@(Get-ChildItem -LiteralPath $raiz -Filter 'ADUANA-CAPACIDAD-*' -ErrorAction SilentlyContinue).Count -eq 0)

    # ------------------------------------------------------------------------------------------
    Write-Host '== Microsoft Defender con EICAR'
    # La cadena de prueba EICAR se compone aquí para no guardarla entera en el repositorio.
    $eicar = 'X5O!P%@AP[4\PZX54(P^)7CC)7}$' + 'EICAR-STANDARD-ANTIVIRUS-TEST-FILE!$H+H*'
    $carpetaEicar = Join-Path $trabajo 'eicar'
    $null = New-Item -ItemType Directory -Path $carpetaEicar
    $ficheroEicar = Join-Path $carpetaEicar 'prueba.txt'
    try { [IO.File]::WriteAllText($ficheroEicar, $eicar) } catch { Write-Host "Defender ha bloqueado la escritura: $($_.Exception.Message)" }
    Start-Sleep -Seconds 2
    if (-not (Test-Path -LiteralPath $ficheroEicar)) {
        Omitir 'Defender detecta EICAR al inspeccionar' 'la protección en tiempo real lo ha quitado antes de poder inspeccionarlo, lo que también demuestra que Defender funciona'
    }
    else {
        $r = Invoke-AduanaCli -Argumentos @('inspeccionar', $carpetaEicar, '--json')
        $j = ConvertFrom-SalidaJson $r
        if ($j -and $j.antivirus.estado -eq 'no-disponible') {
            Omitir 'Defender detecta EICAR al inspeccionar' 'Defender no está disponible en este runner'
        }
        else {
            Comprobar 'Defender detecta EICAR al inspeccionar' ($j -and $j.antivirus.estado -eq 'detecciones' -and $r.Codigo -eq 2) (Get-Diagnostico $r)
            $conAntivirus = @()
            if ($j) { $conAntivirus = @($j.hallazgos | Where-Object { $_.regla -eq 'antivirus' }) }
            Comprobar 'y lo anota como hallazgo antivirus' ($conAntivirus.Count -ge 1) (Get-Diagnostico $r)
        }
    }

    # ------------------------------------------------------------------------------------------
    Write-Host '== Centinela y Sandbox'
    $inicio = Get-Date
    $r = Invoke-AduanaCli -Argumentos @('centinela', '--durante', '3')
    $segundos = ((Get-Date) - $inicio).TotalSeconds
    Comprobar 'el centinela compila con el C# de .NET Framework y termina en 0' ($r.Codigo -eq 0) (Get-Diagnostico $r)
    Comprobar 'y vigila el tiempo pedido' ($segundos -ge 3) "tardó $segundos s"
    $r = Invoke-AduanaCli -Argumentos @('centinela', '--aprender')
    Comprobar 'centinela --aprender devuelve 0' ($r.Codigo -eq 0) (Get-Diagnostico $r)
    if (Find-AduanaSandbox) {
        Omitir 'sandbox sin Windows Sandbox devuelve 3' 'este Windows sí tiene Sandbox'
    }
    else {
        $r = Invoke-AduanaCli -Argumentos @('sandbox', $trabajo)
        Comprobar 'sandbox sin Windows Sandbox devuelve 3' ($r.Codigo -eq 3) (Get-Diagnostico $r)
    }
}
catch {
    $script:Fallidas++
    Write-Host "FALLO     error inesperado: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace
    Write-Host "::error::Error inesperado en la integración: $($_.Exception.Message)"
}
finally {
    if ($discoAdjunto) {
        $null = Invoke-Diskpart -Ordenes @("select vdisk file=`"$vhd`"", 'detach vdisk')
    }
    Remove-Item -LiteralPath $trabajo -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host "Resultado, $($script:Correctas) correctas, $($script:Fallidas) fallidas y $($script:Omitidas) omitidas."
if ($script:Fallidas -gt 0) { exit 1 }
exit 0

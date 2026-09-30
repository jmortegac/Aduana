# Capa fina con todo lo que toca Windows: registro, discos, PnP, Defender, marcas de origen,
# procesos externos y bloqueo de sesión. Las órdenes solo llegan al sistema a través de estas
# funciones, y las pruebas las sustituyen por mocks.

function Test-AduanaAdmin {
    if (-not (Test-AduanaWindows)) {
        return $false
    }
    $identidad = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $identidad
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Registro ----------------------------------------------------------------------------------------

function Get-AduanaValorRegistro {
    param([Parameter(Mandatory = $true)][string]$Ruta, [Parameter(Mandatory = $true)][string]$Nombre)
    if (-not (Test-Path -LiteralPath $Ruta)) {
        return @{ Existe = $false; Valor = $null; Tipo = $null }
    }
    $clave = Get-Item -LiteralPath $Ruta
    if ($clave.GetValueNames() -notcontains $Nombre) {
        return @{ Existe = $false; Valor = $null; Tipo = $null }
    }
    return @{ Existe = $true; Valor = $clave.GetValue($Nombre); Tipo = [string]$clave.GetValueKind($Nombre) }
}

function Set-AduanaValorRegistro {
    param(
        [Parameter(Mandatory = $true)][string]$Ruta,
        [Parameter(Mandatory = $true)][string]$Nombre,
        [Parameter(Mandatory = $true)]$Valor,
        [string]$Tipo = 'DWord'
    )
    if (-not (Test-Path -LiteralPath $Ruta)) {
        $null = New-Item -Path $Ruta -Force
    }
    $null = New-ItemProperty -LiteralPath $Ruta -Name $Nombre -Value $Valor -PropertyType $Tipo -Force
}

function Remove-AduanaValorRegistro {
    param([Parameter(Mandatory = $true)][string]$Ruta, [Parameter(Mandatory = $true)][string]$Nombre)
    if (Test-Path -LiteralPath $Ruta) {
        Remove-ItemProperty -LiteralPath $Ruta -Name $Nombre -ErrorAction SilentlyContinue
    }
}

function Test-AduanaClaveRegistro {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    return (Test-Path -LiteralPath $Ruta)
}

# Borra una clave solo si está vacía, sin valores ni subclaves, para no llevarse nada que otro
# programa haya guardado en ella después de preparar el equipo.
function Remove-AduanaClaveRegistroVacia {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    if (-not (Test-Path -LiteralPath $Ruta)) { return }
    $clave = Get-Item -LiteralPath $Ruta
    if ($clave.ValueCount -gt 0 -or $clave.SubKeyCount -gt 0) { return }
    Remove-Item -LiteralPath $Ruta -Force
}

function Invoke-AduanaMountvol {
    param([bool]$Activar)
    $opcion = '/N'
    if ($Activar) { $opcion = '/E' }
    & mountvol.exe $opcion | Out-Null
    return $LASTEXITCODE
}

# Discos -------------------------------------------------------------------------------------------

function Get-AduanaDisco {
    param([Parameter(Mandatory = $true)][int]$Numero)
    return (Get-Disk -Number $Numero -ErrorAction SilentlyContinue)
}

function Get-AduanaDiscosExtraibles {
    return @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -or $_.BusType -eq 'File Backed Virtual' })
}

# Devuelve $false si Windows no deja poner el disco en solo lectura, algo habitual en pendrives que
# se anuncian como medio extraíble, porque a esos no los deja poner fuera de línea.
function Set-AduanaDiscoSoloLectura {
    param([Parameter(Mandatory = $true)][int]$Numero)
    try {
        # El atributo de solo lectura solo se puede cambiar con el disco fuera de línea.
        Set-Disk -Number $Numero -IsOffline $true -ErrorAction Stop
        Set-Disk -Number $Numero -IsReadOnly $true -ErrorAction Stop
    }
    catch {
        Set-Disk -Number $Numero -IsOffline $false -ErrorAction SilentlyContinue
        return $false
    }
    Set-Disk -Number $Numero -IsOffline $false
    return $true
}

function Add-AduanaLetrasDisco {
    param([Parameter(Mandatory = $true)][int]$Numero)
    foreach ($p in @(Get-Partition -DiskNumber $Numero -ErrorAction SilentlyContinue)) {
        if ([string]$p.DriveLetter -match '^[A-Za-z]$') { continue }
        if (@('System', 'Reserved', 'Recovery') -contains [string]$p.Type) { continue }
        try {
            Add-PartitionAccessPath -DiskNumber $Numero -PartitionNumber $p.PartitionNumber -AssignDriveLetter -ErrorAction Stop
        }
        catch {
            Write-Verbose "La partición $($p.PartitionNumber) no admite letra."
        }
    }
    $letras = @()
    foreach ($p in @(Get-Partition -DiskNumber $Numero -ErrorAction SilentlyContinue)) {
        if ([string]$p.DriveLetter -match '^[A-Za-z]$') { $letras += [string]$p.DriveLetter }
    }
    return , $letras
}

function Invoke-AduanaFormateo {
    param(
        [Parameter(Mandatory = $true)][int]$Numero,
        [Parameter(Mandatory = $true)][string]$Nombre,
        [bool]$Completo = $false
    )
    Set-Disk -Number $Numero -IsReadOnly $false -ErrorAction SilentlyContinue
    # Un pendrive nuevo sin inicializar (RAW) no admite Clear-Disk.
    if ([string](Get-Disk -Number $Numero).PartitionStyle -ne 'RAW') {
        Clear-Disk -Number $Numero -RemoveData -RemoveOEM -Confirm:$false
    }
    Initialize-Disk -Number $Numero -PartitionStyle MBR -ErrorAction SilentlyContinue
    $particion = New-Partition -DiskNumber $Numero -UseMaximumSize -AssignDriveLetter
    $null = Format-Volume -Partition $particion -FileSystem exFAT -NewFileSystemLabel $Nombre -Full:$Completo -Confirm:$false -Force
    return [string](Get-Partition -DiskNumber $Numero -PartitionNumber $particion.PartitionNumber).DriveLetter
}

function Get-AduanaDiscoDeRuta {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    $raiz = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Ruta))
    if ($raiz -notmatch '^([A-Za-z]):\\$') { return $null }
    $particion = Get-Partition -DriveLetter $Matches[1] -ErrorAction SilentlyContinue
    if ($null -eq $particion) { return $null }
    return $particion.DiskNumber
}

# PnP: sube por los padres de un dispositivo hasta el dispositivo USB compuesto, el que tiene
# VID y PID pero no número de interfaz (MI_).
function Get-AduanaPadrePnp {
    param([string]$Id)
    $p = Get-PnpDeviceProperty -InstanceId $Id -KeyName 'DEVPKEY_Device_Parent' -ErrorAction SilentlyContinue
    if ($null -eq $p) { return $null }
    return [string]$p.Data
}

function Find-AduanaPadreUsb {
    param([string]$Id)
    $actual = $Id
    for ($i = 0; $i -lt 8 -and $actual; $i++) {
        if ($actual -match '^USB\\VID_[0-9A-F]{4}&PID_[0-9A-F]{4}\\') {
            return $actual
        }
        $actual = Get-AduanaPadrePnp -Id $actual
    }
    return $null
}

function Test-AduanaDescendiente {
    param([string]$Id, [string]$Ancestro)
    $actual = $Id
    for ($i = 0; $i -lt 8 -and $actual; $i++) {
        if ($actual -eq $Ancestro) { return $true }
        $actual = Get-AduanaPadrePnp -Id $actual
    }
    return $false
}

function Get-AduanaDispositivo {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    if (-not (Test-AduanaWindows)) { return $null }
    $completa = [IO.Path]::GetFullPath($Ruta)
    $raiz = [IO.Path]::GetPathRoot($completa)
    if ($completa.TrimEnd('\') -ne $raiz.TrimEnd('\') -or $raiz -notmatch '^([A-Za-z]):\\$') {
        return $null
    }
    $letra = $Matches[1]
    $particion = Get-Partition -DriveLetter $letra -ErrorAction SilentlyContinue
    if ($null -eq $particion) { return $null }
    $disco = Get-Disk -Number $particion.DiskNumber
    if ($disco.BusType -ne 'USB') { return $null }
    $volumen = Get-Volume -DriveLetter $letra -ErrorAction SilentlyContinue

    $ocultas = New-Object 'System.Collections.Generic.List[string]'
    $gptOcultables = @('{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}', '{e3c9e316-0b5c-4db8-817d-f92df00215ae}')
    foreach ($p in @(Get-Partition -DiskNumber $disco.Number)) {
        $tieneLetra = [string]$p.DriveLetter -match '^[A-Za-z]$'
        $montajes = @($p.AccessPaths | Where-Object { $_ -and $_ -notlike '\\?\Volume*' })
        $sistema = @('System', 'Reserved', 'Recovery') -contains [string]$p.Type -or $gptOcultables -contains ([string]$p.GptType).ToLowerInvariant()
        if (-not $tieneLetra -and $montajes.Count -eq 0 -and -not $sistema) {
            $ocultas.Add("partición $($p.PartitionNumber) de $(Format-AduanaTamano $p.Size), tipo $($p.Type)")
        }
    }

    $interfaces = New-Object 'System.Collections.Generic.List[object]'
    $unidad = Get-CimInstance -ClassName Win32_DiskDrive | Where-Object { $_.Index -eq $disco.Number } | Select-Object -First 1
    if ($null -ne $unidad) {
        $compuesto = Find-AduanaPadreUsb -Id $unidad.PNPDeviceID
        if ($compuesto) {
            $vidPid = Get-AduanaIdTeclado -Texto $compuesto
            foreach ($clase in @('Keyboard', 'HIDClass', 'Mouse', 'Net', 'CDROM')) {
                foreach ($d in @(Get-PnpDevice -PresentOnly -Class $clase -ErrorAction SilentlyContinue)) {
                    $mismo = ($vidPid -and $d.InstanceId -like "*$vidPid*") -or (Test-AduanaDescendiente -Id $d.InstanceId -Ancestro $compuesto)
                    if ($mismo) {
                        $interfaces.Add(@{ Clase = $clase; Nombre = [string]$d.FriendlyName })
                    }
                }
            }
        }
    }
    $descripciones = New-Object 'System.Collections.Generic.List[string]'
    foreach ($i in $interfaces) { $descripciones.Add("$($i.Clase) $($i.Nombre)") }
    $sistemaFicheros = ''
    if ($null -ne $volumen) { $sistemaFicheros = [string]$volumen.FileSystem }
    return @{
        Dispositivo        = [ordered]@{
            bus             = 'USB'
            fabricante      = [string]$disco.Manufacturer
            modelo          = [string]$disco.FriendlyName
            sistemaFicheros = $sistemaFicheros
            interfaces      = $descripciones
        }
        Interfaces         = $interfaces
        ParticionesOcultas = $ocultas
    }
}

# Antivirus y VirusTotal --------------------------------------------------------------------------

function Find-AduanaMpCmdRun {
    if (-not (Test-AduanaWindows)) { return $null }
    # La versión de la plataforma más reciente vive en ProgramData; la de Program Files es la base.
    $plataforma = Join-Path $env:ProgramData 'Microsoft\Windows Defender\Platform'
    if (Test-Path -LiteralPath $plataforma) {
        $ultima = Get-ChildItem -LiteralPath $plataforma -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($null -ne $ultima) {
            $candidato = Join-Path $ultima.FullName 'MpCmdRun.exe'
            if (Test-Path -LiteralPath $candidato) { return $candidato }
        }
    }
    $base = Join-Path $env:ProgramFiles 'Windows Defender\MpCmdRun.exe'
    if (Test-Path -LiteralPath $base) { return $base }
    return $null
}

function Invoke-AduanaDefender {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    $mp = Find-AduanaMpCmdRun
    if (-not $mp) {
        return @{ Disponible = $false; Codigo = -1; Salida = '' }
    }
    $r = Invoke-AduanaProceso -Programa $mp -Argumentos @('-Scan', '-ScanType', '3', '-File', $Ruta, '-DisableRemediation')
    return @{ Disponible = $true; Codigo = $r.Codigo; Salida = $r.Salida + "`n" + $r.Error }
}

function Get-AduanaVirusTotal {
    param([Parameter(Mandatory = $true)][string]$Hash, [Parameter(Mandatory = $true)][string]$Clave)
    if ($PSVersionTable.PSEdition -ne 'Core') {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    try {
        $r = Invoke-RestMethod -Uri "https://www.virustotal.com/api/v3/files/$Hash" -Headers @{ 'x-apikey' = $Clave } -Method Get -UseBasicParsing
        return @{ Encontrado = $true; Maliciosos = [int]$r.data.attributes.last_analysis_stats.malicious }
    }
    catch {
        $estado = 0
        try { $estado = [int]$_.Exception.Response.StatusCode } catch { $estado = 0 }
        if ($estado -eq 404) {
            return @{ Encontrado = $false; Maliciosos = 0 }
        }
        throw
    }
}

function Wait-AduanaPausa {
    param([int]$Segundos)
    Start-Sleep -Seconds $Segundos
}

# Ficheros ----------------------------------------------------------------------------------------

function Get-AduanaSistemaFicheros {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    try {
        $raiz = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Ruta))
        return (New-Object IO.DriveInfo $raiz).DriveFormat
    }
    catch {
        return ''
    }
}

function Get-AduanaEspacioLibre {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    $raiz = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Ruta))
    return [long](New-Object IO.DriveInfo $raiz).AvailableFreeSpace
}

# La marca de origen de Windows es el flujo alternativo Zone.Identifier. ZoneId=3 es «Internet»,
# lo que activa la Vista protegida de Office y el aviso de SmartScreen.
function Set-AduanaMarcaOrigen {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    try {
        $contenido = "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=about:internet`r`n"
        Set-Content -LiteralPath $Ruta -Stream 'Zone.Identifier' -Value $contenido -NoNewline -Encoding Ascii -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# Tras escribir los datos de prueba hay que leerlos del pendrive y no de la caché de Windows. Con
# permisos de administrador basta con poner el disco fuera de línea y otra vez en línea; sin ellos
# se pide al usuario que lo desenchufe y lo vuelva a conectar.
function Clear-AduanaCacheDisco {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    if (-not (Test-AduanaWindows)) { return }
    $raiz = [IO.Path]::GetPathRoot([IO.Path]::GetFullPath($Ruta))
    $numero = Get-AduanaDiscoDeRuta -Ruta $Ruta
    $hecho = $false
    if ((Test-AduanaAdmin) -and $null -ne $numero) {
        try {
            Set-Disk -Number $numero -IsOffline $true -ErrorAction Stop
            Set-Disk -Number $numero -IsOffline $false -ErrorAction Stop
            $hecho = $true
            $espera = 15
        }
        catch {
            Write-Verbose 'Windows no deja poner este disco fuera de línea; se pide al usuario que lo reconecte.'
        }
    }
    if (-not $hecho) {
        $null = Read-AduanaConfirmacion -Mensaje 'Desenchufa el pendrive, vuelve a conectarlo y pulsa Intro'
        $espera = 60
    }
    for ($i = 0; $i -lt $espera; $i++) {
        if (Test-Path -LiteralPath $raiz) { return }
        Start-Sleep -Seconds 1
    }
    throw (New-AduanaError "El pendrive no ha vuelto a aparecer en $raiz.")
}

function Read-AduanaConfirmacion {
    param([Parameter(Mandatory = $true)][string]$Mensaje)
    return (Read-Host -Prompt $Mensaje)
}

# Programas externos ------------------------------------------------------------------------------

function Find-AduanaPrograma {
    param([Parameter(Mandatory = $true)][string[]]$Nombres, [string[]]$Rutas = @())
    foreach ($n in $Nombres) {
        $c = Get-Command -Name $n -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($null -ne $c) { return $c.Path }
    }
    foreach ($r in $Rutas) {
        if ($r -and (Test-Path -LiteralPath $r -PathType Leaf)) { return $r }
    }
    return $null
}

# Primero el ssh-keygen de Windows y solo después el del PATH. Así un ssh-keygen.exe puesto en una
# carpeta del PATH no puede colarse en la firma, y no se usa por sorpresa el de Git para Windows.
function Find-AduanaSshKeygen {
    if ($env:WINDIR) {
        $sistema = Join-Path $env:WINDIR 'System32\OpenSSH\ssh-keygen.exe'
        if (Test-Path -LiteralPath $sistema -PathType Leaf) { return $sistema }
    }
    return (Find-AduanaPrograma -Nombres @('ssh-keygen'))
}

function Find-Aduana7z {
    $rutas = @()
    if ($env:ProgramFiles) { $rutas += (Join-Path $env:ProgramFiles '7-Zip\7z.exe') }
    return (Find-AduanaPrograma -Nombres @('7z', '7zz') -Rutas $rutas)
}

function Find-AduanaExiftool {
    return (Find-AduanaPrograma -Nombres @('exiftool'))
}

function Find-AduanaDangerzone {
    $rutas = @()
    if ($env:ProgramFiles) { $rutas += (Join-Path $env:ProgramFiles 'Dangerzone\dangerzone-cli.exe') }
    return (Find-AduanaPrograma -Nombres @('dangerzone-cli') -Rutas $rutas)
}

# Ejecuta un programa con la entrada estándar exacta en bytes. La redirección de PowerShell 5.1
# pasa por texto y reescribe la codificación, lo que rompería la verificación de una firma.
function Invoke-AduanaProceso {
    param(
        [Parameter(Mandatory = $true)][string]$Programa,
        [string[]]$Argumentos = @(),
        [byte[]]$Entrada = $null
    )
    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $Programa
    $info.Arguments = (@($Argumentos | ForEach-Object { ConvertTo-AduanaArgumento -Argumento $_ }) -join ' ')
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.RedirectStandardInput = ($null -ne $Entrada)
    $info.CreateNoWindow = $true
    $proceso = [Diagnostics.Process]::Start($info)
    try {
        # Se leen las dos salidas a la vez para que ninguna llene su búfer y bloquee al proceso.
        $salida = $proceso.StandardOutput.ReadToEndAsync()
        $errores = $proceso.StandardError.ReadToEndAsync()
        if ($null -ne $Entrada) {
            $proceso.StandardInput.BaseStream.Write($Entrada, 0, $Entrada.Length)
            $proceso.StandardInput.Close()
        }
        $proceso.WaitForExit()
        return @{ Codigo = $proceso.ExitCode; Salida = $salida.Result; Error = $errores.Result }
    }
    finally {
        $proceso.Dispose()
    }
}

# La firma se lanza sin redirigir nada para que ssh-keygen pueda pedir la frase de paso.
function Invoke-AduanaFirmaSsh {
    param(
        [Parameter(Mandatory = $true)][string]$SshKeygen,
        [Parameter(Mandatory = $true)][string]$Clave,
        [Parameter(Mandatory = $true)][string]$Fichero
    )
    & $SshKeygen -Y sign -f $Clave -n aduana $Fichero
    return $LASTEXITCODE
}

function Get-AduanaHuellaClave {
    param([Parameter(Mandatory = $true)][string]$SshKeygen, [Parameter(Mandatory = $true)][string]$Publica)
    $r = Invoke-AduanaProceso -Programa $SshKeygen -Argumentos @('-lf', $Publica)
    $tokens = @($r.Salida.Trim() -split '\s+')
    if ($r.Codigo -ne 0 -or $tokens.Count -lt 2) {
        return $null
    }
    return $tokens[1]
}

function Invoke-Aduana7z {
    param([string]$Programa, [string]$Salida, [string]$Carpeta)
    # Sin contraseña tras -p, 7-Zip la pide por teclado y no queda en el historial.
    & $Programa a -t7z -mhe=on -p $Salida $Carpeta
    return $LASTEXITCODE
}

function Invoke-AduanaExiftool {
    param([string]$Programa, [string]$Ruta)
    & $Programa -all= -overwrite_original -q $Ruta | Out-Null
    return $LASTEXITCODE
}

function Invoke-AduanaDangerzone {
    param([string]$Programa, [string]$Origen, [string]$Destino)
    & $Programa $Origen --output-filename $Destino | Out-Null
    return $LASTEXITCODE
}

# Centinela y Sandbox -----------------------------------------------------------------------------

function Get-AduanaTecladosPresentes {
    $ids = New-Object 'System.Collections.Generic.List[string]'
    foreach ($d in @(Get-PnpDevice -Class Keyboard -PresentOnly -ErrorAction SilentlyContinue)) {
        $id = Get-AduanaIdTeclado -Texto $d.InstanceId
        if ($id -and -not $ids.Contains($id)) { $ids.Add($id) }
    }
    return , $ids
}

function Start-AduanaCentinela {
    param([Parameter(Mandatory = $true)][int]$Segundos, [string[]]$Conocidos = @())
    if (-not ('AduanaCentinela' -as [type])) {
        Add-Type -TypeDefinition (Get-AduanaCodigoCentinela) -Language CSharp
    }
    $disparador = [AduanaCentinela]::Vigilar($Segundos, $Conocidos)
    return @{ Disparado = ($null -ne $disparador); Dispositivo = $disparador }
}

function Find-AduanaSandbox {
    if (-not $env:WINDIR) { return $null }
    $ruta = Join-Path $env:WINDIR 'System32\WindowsSandbox.exe'
    if (Test-Path -LiteralPath $ruta) { return $ruta }
    return $null
}

function Start-AduanaSandbox {
    param([Parameter(Mandatory = $true)][string]$Configuracion)
    Start-Process -FilePath $Configuracion
}

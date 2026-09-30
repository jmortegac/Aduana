# Utilidades comunes de Aduana para Windows: versión, errores, estado, argumentos y salida.
# Nada de este fichero toca el sistema más allá de la consola, así que se prueba entero en Linux.

function Get-AduanaVersion {
    return '0.3.0'
}

# Los errores que Aduana lanza a propósito llevan su código de retorno dentro de la excepción,
# para que el punto de entrada distinga un error de uso (3) de un fallo inesperado.
function New-AduanaError {
    param(
        [Parameter(Mandatory = $true)][string]$Mensaje,
        [int]$Codigo = 3
    )
    $excepcion = New-Object System.Exception $Mensaje
    $excepcion.Data['AduanaCodigo'] = $Codigo
    return $excepcion
}

function Test-AduanaWindows {
    # PowerShell 5.1 solo existe en Windows y no define $IsWindows, que con StrictMode daría error.
    if ($PSVersionTable.PSEdition -ne 'Core') {
        return $true
    }
    return [bool](Get-Variable -Name IsWindows -ValueOnly -ErrorAction SilentlyContinue)
}

# ADUANA_ESTADO permite a las pruebas usar una carpeta temporal sin tocar la del usuario.
function Get-AduanaDirectorioEstado {
    if ($env:ADUANA_ESTADO) {
        return $env:ADUANA_ESTADO
    }
    if ($env:LOCALAPPDATA) {
        return (Join-Path $env:LOCALAPPDATA 'Aduana')
    }
    return (Join-Path $HOME '.aduana')
}

function Get-AduanaFecha {
    param([datetime]$Momento = (Get-Date))
    return $Momento.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture)
}

function Format-AduanaTamano {
    param([double]$Bytes)
    $unidades = @('B', 'KB', 'MB', 'GB', 'TB')
    $i = 0
    while ($Bytes -ge 1000 -and $i -lt $unidades.Count - 1) {
        $Bytes = $Bytes / 1000
        $i++
    }
    # Coma decimal a mano, porque en modo de globalización invariante no hay cultura es-ES.
    $texto = $Bytes.ToString('0.#', [Globalization.CultureInfo]::InvariantCulture).Replace('.', ',')
    return "$texto $($unidades[$i])"
}

# Rutas y caracteres peligrosos ------------------------------------------------------------------

function ConvertTo-AduanaNfc {
    param([string]$Texto)
    return $Texto.Normalize([Text.NormalizationForm]::FormC)
}

function Get-AduanaRutaRelativa {
    param(
        [Parameter(Mandatory = $true)][string]$Raiz,
        [Parameter(Mandatory = $true)][string]$Ruta
    )
    $raizNormal = $Raiz.TrimEnd('\', '/')
    if ($Ruta.Length -gt $raizNormal.Length -and $Ruta.StartsWith($raizNormal, [StringComparison]::OrdinalIgnoreCase)) {
        $resto = $Ruta.Substring($raizNormal.Length).TrimStart('\', '/')
        if ($resto) {
            return $resto.Replace('\', '/')
        }
    }
    if ($Ruta.TrimEnd('\', '/') -eq $raizNormal) {
        return '.'
    }
    return $Ruta.Replace('\', '/')
}

function Test-AduanaRutaDentro {
    param(
        [Parameter(Mandatory = $true)][string]$Hija,
        [Parameter(Mandatory = $true)][string]$Padre
    )
    $separadores = [char[]]@('\', '/')
    $h = [IO.Path]::GetFullPath($Hija).TrimEnd($separadores) + [IO.Path]::DirectorySeparatorChar
    $p = [IO.Path]::GetFullPath($Padre).TrimEnd($separadores) + [IO.Path]::DirectorySeparatorChar
    $comparacion = [StringComparison]::Ordinal
    if (Test-AduanaWindows) {
        $comparacion = [StringComparison]::OrdinalIgnoreCase
    }
    return $h.StartsWith($p, $comparacion)
}

# Un carácter es «peligroso de mostrar» si es de control o si figura en las listas de caracteres
# de las reglas (bidi, invisibles y puntos falsos). Imprimirlo tal cual podría dar la vuelta a la
# propia línea del informe, que es justo el engaño que Aduana intenta señalar.
function Test-AduanaCaracterPeligroso {
    param([int]$Codigo, $Reglas)
    if ($Codigo -lt 0x20 -or $Codigo -eq 0x7f) {
        return $true
    }
    if ($null -ne $Reglas -and $Reglas.Caracteres.ContainsKey($Codigo)) {
        return $true
    }
    return $false
}

function Format-AduanaNombreSeguro {
    param([string]$Texto, $Reglas)
    if ($null -eq $Texto) {
        return ''
    }
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $Texto.ToCharArray()) {
        $n = [int]$c
        if (Test-AduanaCaracterPeligroso -Codigo $n -Reglas $Reglas) {
            [void]$sb.Append([char]0x27E8).Append('U+').Append($n.ToString('X4')).Append([char]0x27E9)
        }
        else {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString()
}

# JSON propio ------------------------------------------------------------------------------------
# ConvertTo-Json de PowerShell 5.1 y 7 no producen lo mismo (sangría, escapes, arrays de un solo
# elemento), y el contrato exige una salida idéntica en todas partes y con los caracteres
# peligrosos escapados. Por eso Aduana serializa a mano.

function ConvertTo-AduanaJsonTexto {
    param([string]$Texto, $Reglas)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($c in $Texto.ToCharArray()) {
        $n = [int]$c
        if ($n -eq 0x22) { [void]$sb.Append('\"') }
        elseif ($n -eq 0x5c) { [void]$sb.Append('\\') }
        elseif ($n -eq 0x0a) { [void]$sb.Append('\n') }
        elseif ($n -eq 0x0d) { [void]$sb.Append('\r') }
        elseif ($n -eq 0x09) { [void]$sb.Append('\t') }
        elseif (Test-AduanaCaracterPeligroso -Codigo $n -Reglas $Reglas) {
            [void]$sb.Append('\u').Append($n.ToString('x4'))
        }
        else { [void]$sb.Append($c) }
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

function ConvertTo-AduanaJson {
    param(
        [AllowNull()][object]$Valor,
        $Reglas = $null,
        [int]$Nivel = 0
    )
    $sangria = '  ' * ($Nivel + 1)
    $cierre = '  ' * $Nivel
    if ($null -eq $Valor) {
        return 'null'
    }
    if ($Valor -is [bool]) {
        if ($Valor) { return 'true' }
        return 'false'
    }
    if ($Valor -is [string] -or $Valor -is [char] -or $Valor -is [enum]) {
        return (ConvertTo-AduanaJsonTexto -Texto ([string]$Valor) -Reglas $Reglas)
    }
    if ($Valor -is [int] -or $Valor -is [long] -or $Valor -is [double] -or $Valor -is [decimal] -or
        $Valor -is [int16] -or $Valor -is [byte] -or $Valor -is [uint32] -or $Valor -is [uint64] -or $Valor -is [single]) {
        return ([Convert]::ToString($Valor, [Globalization.CultureInfo]::InvariantCulture))
    }
    if ($Valor -is [Collections.IDictionary]) {
        if ($Valor.Count -eq 0) {
            return '{}'
        }
        $partes = New-Object 'System.Collections.Generic.List[string]'
        foreach ($clave in $Valor.Keys) {
            $texto = ConvertTo-AduanaJson -Valor $Valor[$clave] -Reglas $Reglas -Nivel ($Nivel + 1)
            $partes.Add($sangria + (ConvertTo-AduanaJsonTexto -Texto ([string]$clave) -Reglas $Reglas) + ': ' + $texto)
        }
        return "{`n" + ($partes -join ",`n") + "`n$cierre}"
    }
    if ($Valor -is [Collections.IEnumerable]) {
        $partes = New-Object 'System.Collections.Generic.List[string]'
        foreach ($elemento in $Valor) {
            $partes.Add($sangria + (ConvertTo-AduanaJson -Valor $elemento -Reglas $Reglas -Nivel ($Nivel + 1)))
        }
        if ($partes.Count -eq 0) {
            return '[]'
        }
        return "[`n" + ($partes -join ",`n") + "`n$cierre]"
    }
    if ($Valor -is [Management.Automation.PSCustomObject]) {
        $diccionario = [ordered]@{}
        foreach ($propiedad in $Valor.PSObject.Properties) {
            $diccionario[$propiedad.Name] = $propiedad.Value
        }
        return (ConvertTo-AduanaJson -Valor $diccionario -Reglas $Reglas -Nivel $Nivel)
    }
    return (ConvertTo-AduanaJsonTexto -Texto ([string]$Valor) -Reglas $Reglas)
}

# Argumentos para procesos externos --------------------------------------------------------------
# ProcessStartInfo.Arguments es una sola cadena en .NET Framework, así que hay que entrecomillar
# cada argumento con las reglas de CommandLineToArgvW para que una ruta con espacios o comillas
# llegue entera.
function ConvertTo-AduanaArgumento {
    param([AllowEmptyString()][string]$Argumento)
    if ($Argumento -eq '') {
        return '""'
    }
    if ($Argumento -notmatch '[\s"]') {
        return $Argumento
    }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    $barras = 0
    foreach ($c in $Argumento.ToCharArray()) {
        if ($c -eq '\') {
            $barras++
        }
        elseif ($c -eq '"') {
            [void]$sb.Append(('\' * (2 * $barras + 1))).Append('"')
            $barras = 0
        }
        else {
            if ($barras -gt 0) {
                [void]$sb.Append(('\' * $barras))
            }
            [void]$sb.Append($c)
            $barras = 0
        }
    }
    if ($barras -gt 0) {
        [void]$sb.Append(('\' * (2 * $barras)))
    }
    [void]$sb.Append('"')
    return $sb.ToString()
}

# Argumentos de la línea de órdenes --------------------------------------------------------------

function Get-AduanaDefinicionOrdenes {
    return @{
        'ayuda'                      = @{ Min = 0; Max = 0; Valores = @(); Booleanas = @() }
        'version'                    = @{ Min = 0; Max = 0; Valores = @(); Booleanas = @() }
        'preparar-equipo'            = @{ Min = 0; Max = 0; Valores = @(); Booleanas = @('sin-automontaje') }
        'restaurar-equipo'           = @{ Min = 0; Max = 0; Valores = @(); Booleanas = @() }
        'montar'                     = @{ Min = 0; Max = 1; Valores = @(); Booleanas = @() }
        'inspeccionar'               = @{ Min = 1; Max = 1; Valores = @(); Booleanas = @('json', 'virustotal', 'sin-antivirus') }
        'copiar'                     = @{ Min = 2; Max = 2; Valores = @(); Booleanas = @('incluir-peligrosos', 'desinfectar', 'json') }
        'verificar'                  = @{ Min = 1; Max = 1; Valores = @('firmantes', 'confiar'); Booleanas = @('json') }
        'salida-preparar'            = @{ Min = 1; Max = 1; Valores = @('nombre'); Booleanas = @('borrado-completo', 'si') }
        'salida-limpiar'             = @{ Min = 1; Max = 1; Valores = @(); Booleanas = @('solo-informe') }
        'salida-comprobar-capacidad' = @{ Min = 1; Max = 1; Valores = @('limite'); Booleanas = @() }
        'salida-firmar'              = @{ Min = 1; Max = 1; Valores = @('clave'); Booleanas = @() }
        'salida-cifrar'              = @{ Min = 1; Max = 1; Valores = @('salida'); Booleanas = @() }
        'centinela'                  = @{ Min = 0; Max = 0; Valores = @('durante'); Booleanas = @('aprender') }
        'sandbox'                    = @{ Min = 1; Max = 1; Valores = @(); Booleanas = @() }
    }
}

function Get-AduanaAliasOrdenes {
    return @{
        'help'         = 'ayuda'
        '-h'           = 'ayuda'
        '--help'       = 'ayuda'
        '--version'    = 'version'
        'prepare-host' = 'preparar-equipo'
        'restore-host' = 'restaurar-equipo'
        'mount'        = 'montar'
        'inspect'      = 'inspeccionar'
        'copy'         = 'copiar'
        'verify'       = 'verificar'
        'sentinel'     = 'centinela'
    }
}

function Get-AduanaAliasSalida {
    return @{
        'preparar'            = 'preparar'
        'prepare'             = 'preparar'
        'limpiar'             = 'limpiar'
        'clean'               = 'limpiar'
        'comprobar-capacidad' = 'comprobar-capacidad'
        'check-capacity'      = 'comprobar-capacidad'
        'firmar'              = 'firmar'
        'sign'                = 'firmar'
        'cifrar'              = 'cifrar'
        'encrypt'             = 'cifrar'
    }
}

function ConvertFrom-AduanaArgumentos {
    param([AllowNull()][AllowEmptyCollection()][string[]]$Argumentos)
    if ($null -eq $Argumentos -or $Argumentos.Count -eq 0) {
        return @{ Orden = 'ayuda'; Posicionales = @(); Opciones = @{} }
    }
    $definiciones = Get-AduanaDefinicionOrdenes
    $alias = Get-AduanaAliasOrdenes
    $primera = $Argumentos[0].ToLowerInvariant()
    $inicio = 1
    if ($primera -eq 'salida' -or $primera -eq 'out') {
        if ($Argumentos.Count -lt 2) {
            throw (New-AduanaError 'Falta la orden de salida. Las posibles son preparar, limpiar, comprobar-capacidad, firmar y cifrar.')
        }
        $sub = (Get-AduanaAliasSalida)[$Argumentos[1].ToLowerInvariant()]
        if (-not $sub) {
            throw (New-AduanaError "No conozco la orden de salida «$($Argumentos[1])». Las posibles son preparar, limpiar, comprobar-capacidad, firmar y cifrar.")
        }
        $orden = "salida-$sub"
        $inicio = 2
    }
    elseif ($alias.ContainsKey($primera)) {
        $orden = $alias[$primera]
    }
    else {
        $orden = $primera
    }
    if (-not $definiciones.ContainsKey($orden)) {
        throw (New-AduanaError "No conozco la orden «$($Argumentos[0])». Escribe «aduana ayuda» para ver las que hay.")
    }
    $definicion = $definiciones[$orden]
    $posicionales = New-Object 'System.Collections.Generic.List[string]'
    $opciones = @{}
    $i = $inicio
    while ($i -lt $Argumentos.Count) {
        $token = $Argumentos[$i]
        if ($token.StartsWith('--') -and $token.Length -gt 2) {
            $nombre = $token.Substring(2).ToLowerInvariant()
            if ($definicion.Booleanas -contains $nombre) {
                $opciones[$nombre] = $true
            }
            elseif ($definicion.Valores -contains $nombre) {
                if ($i + 1 -ge $Argumentos.Count) {
                    throw (New-AduanaError "A la opción --$nombre le falta su valor.")
                }
                $i++
                $opciones[$nombre] = $Argumentos[$i]
            }
            else {
                throw (New-AduanaError "La orden $orden no admite la opción $token.")
            }
        }
        else {
            $posicionales.Add($token)
        }
        $i++
    }
    if ($posicionales.Count -lt $definicion.Min -or $posicionales.Count -gt $definicion.Max) {
        throw (New-AduanaError "Número de argumentos incorrecto para $orden. Escribe «aduana ayuda» para ver cómo se usa.")
    }
    return @{ Orden = $orden; Posicionales = $posicionales.ToArray(); Opciones = $opciones }
}

function Get-AduanaAyuda {
    return @(
        "Aduana $(Get-AduanaVersion), kit de seguridad para pendrives."
        ''
        'Entrada, cuando te prestan un pendrive'
        '  preparar-equipo [--sin-automontaje]     endurece Windows frente a pendrives (prepare-host)'
        '  restaurar-equipo                        deshace lo anterior (restore-host)'
        '  centinela [--durante 60] [--aprender]   bloquea la sesión si aparece un teclado nuevo (sentinel)'
        '  montar [<disco>]                        monta un disco USB en solo lectura (mount)'
        '  inspeccionar <ruta> [--json] [--virustotal] [--sin-antivirus]   (inspect)'
        '  copiar <origen> <destino> [--incluir-peligrosos] [--desinfectar] [--json]   (copy)'
        '  verificar <ruta> [--firmantes <fichero>] [--confiar <nombre>] [--json]   (verify)'
        '  sandbox <ruta>                          abre la ruta en Windows Sandbox, sin red'
        ''
        'Salida, cuando preparas un pendrive para prestarlo (out)'
        '  salida preparar <disco> [--nombre ADUANA] [--borrado-completo] [--si]   (prepare)'
        '  salida limpiar <ruta> [--solo-informe]                                  (clean)'
        '  salida comprobar-capacidad <ruta> [--limite <MB>]                       (check-capacity)'
        '  salida firmar <ruta> --clave <clave privada ssh>                        (sign)'
        '  salida cifrar <carpeta> [--salida <fichero.7z>]                         (encrypt)'
        ''
        'Códigos de retorno'
        '  0 sin hallazgos peligrosos ni sospechosos, o la orden terminó bien'
        '  1 hay hallazgos sospechosos y ninguno peligroso'
        '  2 hay hallazgos peligrosos, o la verificación falló'
        '  3 error de uso, del entorno, o cancelado'
    )
}

# Salida por consola -----------------------------------------------------------------------------
# Todo lo que Aduana imprime pasa por estas tres funciones, que las pruebas sustituyen por mocks
# para capturar la salida.

function Write-AduanaLinea {
    param([AllowEmptyString()][string]$Texto = '', [string]$Color = '')
    if ($Color -and -not [Console]::IsOutputRedirected) {
        Write-Host $Texto -ForegroundColor $Color
    }
    else {
        [Console]::Out.WriteLine($Texto)
    }
}

function Write-AduanaJson {
    param([Parameter(Mandatory = $true)][string]$Json)
    [Console]::Out.Write($Json)
    [Console]::Out.Write("`n")
}

function Write-AduanaError {
    param([Parameter(Mandatory = $true)][string]$Texto)
    [Console]::Error.WriteLine($Texto)
}

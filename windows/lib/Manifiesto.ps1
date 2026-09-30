# Manifiesto firmado de un pendrive: lista de ficheros con su SHA-256, en un formato que macOS y
# Windows generan byte a byte igual para que una firma hecha en uno se verifique en el otro.

function Get-AduanaNombresManifiesto {
    return @('ADUANA-MANIFIESTO.txt', 'ADUANA-MANIFIESTO.txt.sig', 'ADUANA-CLAVE.pub')
}

# Orden por los bytes UTF-8, que es lo que hace `LC_ALL=C sort` en macOS. Comparar las cadenas
# UTF-16 con Ordinal daría otro orden en cuanto aparece un carácter fuera del plano básico.
function Compare-AduanaUtf8 {
    param([string]$A, [string]$B)
    $ba = [Text.Encoding]::UTF8.GetBytes($A)
    $bb = [Text.Encoding]::UTF8.GetBytes($B)
    $n = [Math]::Min($ba.Length, $bb.Length)
    for ($i = 0; $i -lt $n; $i++) {
        if ($ba[$i] -ne $bb[$i]) {
            return ([int]$ba[$i] - [int]$bb[$i])
        }
    }
    return ($ba.Length - $bb.Length)
}

# Enumera todo lo que entra en el manifiesto: ficheros de cualquier profundidad, ocultos incluidos,
# sin artefactos del sistema ni los propios ficheros del manifiesto. Los enlaces se devuelven
# aparte, porque firmar los rechaza y verificar los cuenta como añadidos.
function Get-AduanaFicherosFirmables {
    param(
        [Parameter(Mandatory = $true)][string]$Raiz,
        [Parameter(Mandatory = $true)]$Reglas
    )
    $raizCompleta = [IO.Path]::GetFullPath($Raiz)
    $ficheros = New-Object 'System.Collections.Generic.List[object]'
    $enlaces = New-Object 'System.Collections.Generic.List[string]'
    $nombresRaros = New-Object 'System.Collections.Generic.List[string]'
    $propios = Get-AduanaNombresManifiesto
    $pila = New-Object 'System.Collections.Generic.Stack[object]'
    $pila.Push(@{ Info = (New-Object IO.DirectoryInfo $raizCompleta); Rel = '' })
    while ($pila.Count -gt 0) {
        $actual = $pila.Pop()
        foreach ($h in $actual.Info.EnumerateFileSystemInfos()) {
            if ($actual.Rel) { $rel = $actual.Rel + '/' + $h.Name } else { $rel = $h.Name }
            $rel = ConvertTo-AduanaNfc -Texto $rel
            if ($h.Name -match "[`r`n]") {
                $nombresRaros.Add($rel)
                continue
            }
            if (Test-AduanaEnlace -Info $h) {
                $enlaces.Add($rel)
                continue
            }
            if (-not $actual.Rel -and $propios -contains $h.Name) {
                continue
            }
            $esDirectorio = $h -is [IO.DirectoryInfo]
            $cabecera = $null
            if (-not $esDirectorio) {
                $cabecera = Read-AduanaCabecera -Ruta $h.FullName
            }
            if (Test-AduanaArtefacto -Nombre $h.Name -Reglas $Reglas -EsDirectorio $esDirectorio -Cabecera $cabecera) {
                continue
            }
            if ($esDirectorio) {
                $pila.Push(@{ Info = $h; Rel = $rel })
            }
            elseif ($h.Name -eq 'desktop.ini') {
                # desktop.ini sin CLSID es un artefacto de Windows que puede reescribirse solo.
                $contenido = Get-AduanaHallazgosContenido -Ruta $h.FullName -Nombre $h.Name -Cabecera $cabecera -Reglas $Reglas
                if ($contenido.Count -gt 0 -and $contenido[0].Regla -eq 'artefacto-sistema') {
                    continue
                }
                $ficheros.Add(@{ Rel = $rel; Completa = $h.FullName })
            }
            else {
                $ficheros.Add(@{ Rel = $rel; Completa = $h.FullName })
            }
        }
    }
    return @{ Ficheros = $ficheros; Enlaces = $enlaces; NombresRaros = $nombresRaros }
}

function Get-AduanaHashFichero {
    param([Parameter(Mandatory = $true)][string]$Ruta)
    return (Get-FileHash -LiteralPath $Ruta -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Diccionario ruta -> hash de lo que hay ahora mismo en el volumen.
function Get-AduanaHashesActuales {
    param([Parameter(Mandatory = $true)]$Ficheros)
    $hashes = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    foreach ($f in $Ficheros) {
        $hashes[$f.Rel] = Get-AduanaHashFichero -Ruta $f.Completa
    }
    return , $hashes
}

function New-AduanaManifiestoTexto {
    param(
        [Parameter(Mandatory = $true)]$Hashes,
        [Parameter(Mandatory = $true)][string]$Fecha
    )
    $rutas = New-Object 'System.Collections.Generic.List[string]'
    foreach ($r in $Hashes.Keys) { $rutas.Add($r) }
    $rutas.Sort([Comparison[string]] { param($a, $b) Compare-AduanaUtf8 $a $b })
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("# Aduana manifiesto v1`n")
    [void]$sb.Append("# fecha: $Fecha`n")
    foreach ($r in $rutas) {
        [void]$sb.Append($Hashes[$r]).Append('  ').Append($r).Append("`n")
    }
    return $sb.ToString()
}

function ConvertFrom-AduanaManifiesto {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Texto)
    $entradas = New-Object 'System.Collections.Generic.Dictionary[string,string]' ([StringComparer]::Ordinal)
    $numero = 0
    foreach ($linea in $Texto.Split("`n")) {
        $numero++
        if ($linea -eq '' -or $linea.StartsWith('#')) {
            continue
        }
        if ($linea -notmatch '^([0-9a-f]{64})  (.+)$') {
            throw (New-AduanaError "El manifiesto está dañado en la línea $numero." 2)
        }
        $entradas[(ConvertTo-AduanaNfc -Texto $Matches[2])] = $Matches[1]
    }
    return , $entradas
}

function Compare-AduanaManifiesto {
    param(
        [Parameter(Mandatory = $true)]$Esperado,
        [Parameter(Mandatory = $true)]$Actual,
        $Enlaces = @()
    )
    $cambios = New-Object 'System.Collections.Generic.List[object]'
    foreach ($ruta in $Esperado.Keys) {
        if (-not $Actual.ContainsKey($ruta)) {
            $cambios.Add([ordered]@{ tipo = 'ausente'; ruta = $ruta })
        }
        elseif ($Actual[$ruta] -ne $Esperado[$ruta]) {
            $cambios.Add([ordered]@{ tipo = 'modificado'; ruta = $ruta })
        }
    }
    foreach ($ruta in $Actual.Keys) {
        if (-not $Esperado.ContainsKey($ruta)) {
            $cambios.Add([ordered]@{ tipo = 'añadido'; ruta = $ruta })
        }
    }
    foreach ($ruta in @($Enlaces)) {
        if ($null -ne $ruta) {
            $cambios.Add([ordered]@{ tipo = 'añadido'; ruta = $ruta })
        }
    }
    $cambios.Sort([Comparison[object]] { param($a, $b) Compare-AduanaUtf8 $a.ruta $b.ruta })
    return , $cambios
}

# Clave pública en formato OpenSSH: «tipo material [comentario]».
function Get-AduanaClavePublica {
    param([Parameter(Mandatory = $true)][string]$Texto)
    $tokens = @($Texto.Trim() -split '\s+')
    for ($i = 0; $i -lt $tokens.Count - 1; $i++) {
        if ($tokens[$i] -match '^(ssh-|ecdsa-|sk-)') {
            return @{ Tipo = $tokens[$i]; Material = $tokens[$i + 1] }
        }
    }
    throw (New-AduanaError 'La clave pública del pendrive no tiene un formato de OpenSSH válido.' 2)
}

# Busca la clave en un fichero allowed_signers y devuelve la identidad con que se guardó.
function Find-AduanaFirmante {
    param([string]$Fichero, [string]$Tipo, [string]$Material)
    if (-not $Fichero -or -not (Test-Path -LiteralPath $Fichero -PathType Leaf)) {
        return $null
    }
    foreach ($linea in [IO.File]::ReadAllLines($Fichero)) {
        $limpia = $linea.Trim()
        if ($limpia -eq '' -or $limpia.StartsWith('#')) {
            continue
        }
        $tokens = @($limpia -split '\s+')
        for ($i = 1; $i -lt $tokens.Count - 1; $i++) {
            if ($tokens[$i] -eq $Tipo -and $tokens[$i + 1] -eq $Material) {
                return $tokens[0]
            }
        }
    }
    return $null
}

function Test-AduanaNombreFirmante {
    param([string]$Nombre)
    return ($Nombre -match '^[^\s,"*?]+$')
}

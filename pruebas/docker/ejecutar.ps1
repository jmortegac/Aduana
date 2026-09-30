# Se ejecuta dentro del contenedor de pruebas. Cuatro comprobaciones, y el código de salida es
# distinto de cero si falla cualquiera:
#   1. todos los .ps1 se analizan sin errores de sintaxis;
#   2. todos los .ps1 llevan BOM UTF-8, sin el cual PowerShell 5.1 los lee como ANSI;
#   3. PSScriptAnalyzer, con las reglas de compatibilidad con Windows PowerShell 5.1;
#   4. las pruebas de Pester.
param([string]$Filtro = '')

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Path (Split-Path -Path $PSScriptRoot -Parent) -Parent
$fallos = 0

$scripts = @(Get-ChildItem -Path (Join-Path $repo 'windows'), (Join-Path $repo 'pruebas') -Recurse -Filter '*.ps1' -File)
Write-Host "== 1. Sintaxis de $($scripts.Count) scripts" -ForegroundColor Cyan
foreach ($s in $scripts) {
    $tokens = $null
    $errores = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($s.FullName, [ref]$tokens, [ref]$errores)
    foreach ($e in $errores) {
        Write-Host "  $($s.FullName):$($e.Extent.StartLineNumber) $($e.Message)" -ForegroundColor Red
        $fallos++
    }
}

Write-Host '== 2. BOM UTF-8' -ForegroundColor Cyan
foreach ($s in $scripts) {
    $b = [IO.File]::ReadAllBytes($s.FullName)
    if ($b.Length -lt 3 -or $b[0] -ne 0xef -or $b[1] -ne 0xbb -or $b[2] -ne 0xbf) {
        Write-Host "  sin BOM: $($s.FullName)" -ForegroundColor Red
        $fallos++
    }
}

Write-Host '== 2b. Caracteres de engaño en crudo en el código fuente' -ForegroundColor Cyan
# El código tiene que nombrarlos por su código ([char]0x202E), nunca llevarlos dentro: un U+202E
# crudo en un .ps1 da la vuelta a lo que ve quien lo revisa.
$prohibidos = @(0x00AD, 0x061C, 0x0701, 0x0702, 0x180E, 0x2024, 0x2060, 0x2E31, 0xFE52, 0xFEFF, 0xFF0E) + (0x200B..0x200F) + (0x202A..0x202E) + (0x2066..0x2069)
foreach ($s in $scripts) {
    $texto = [IO.File]::ReadAllText($s.FullName, [Text.Encoding]::UTF8)
    if ($texto.Length -gt 0 -and [int]$texto[0] -eq 0xFEFF) { $texto = $texto.Substring(1) }
    $numero = 0
    foreach ($linea in $texto.Split("`n")) {
        $numero++
        foreach ($c in $linea.ToCharArray()) {
            if ($prohibidos -contains [int]$c) {
                Write-Host ("  {0}:{1} U+{2:X4}" -f $s.FullName, $numero, [int]$c) -ForegroundColor Red
                $fallos++
            }
        }
    }
}

Write-Host '== 3. PSScriptAnalyzer' -ForegroundColor Cyan
Import-Module PSScriptAnalyzer
$avisos = @(Invoke-ScriptAnalyzer -Path (Join-Path $repo 'windows') -Recurse -Settings (Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'))
foreach ($a in $avisos) {
    Write-Host "  $($a.Severity) $($a.RuleName) $($a.ScriptName):$($a.Line) $($a.Message)" -ForegroundColor Red
}
Write-Host "  $($avisos.Count) avisos"
$fallos += $avisos.Count

Write-Host '== 4. Pester' -ForegroundColor Cyan
Import-Module Pester -MinimumVersion 5.9.1
$configuracion = New-PesterConfiguration
$configuracion.Run.Path = Join-Path (Join-Path $repo 'pruebas') 'windows'
$configuracion.Run.PassThru = $true
$configuracion.Output.Verbosity = 'Normal'
if ($Filtro) {
    $configuracion.Filter.FullName = $Filtro
}
$resultado = Invoke-Pester -Configuration $configuracion
Write-Host "  $($resultado.PassedCount) pruebas bien, $($resultado.FailedCount) mal, $($resultado.SkippedCount) omitidas"
if ($resultado.FailedCount -gt 0 -or $resultado.Result -ne 'Passed') {
    $fallos++
}

if ($fallos -gt 0) {
    Write-Host "RESULTADO: $fallos fallos" -ForegroundColor Red
    exit 1
}
Write-Host 'RESULTADO: todo en verde' -ForegroundColor Green
exit 0

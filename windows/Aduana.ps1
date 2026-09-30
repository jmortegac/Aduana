# Aduana para Windows, kit de seguridad para pendrives.
#
# Uso: powershell -ExecutionPolicy Bypass -File .\windows\Aduana.ps1 ayuda
#
# Funciona con el PowerShell 5.1 que trae Windows y no descarga nada. Las reglas de inspección
# están en ..\reglas\reglas.json, compartidas con la versión de macOS.

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

$lib = Join-Path $PSScriptRoot 'lib'
foreach ($parte in @('Comun', 'Reglas', 'Manifiesto', 'Salida', 'Sistema', 'Centinela', 'Ordenes')) {
    . (Join-Path $lib "$parte.ps1")
}

$codigo = Invoke-Aduana -Argumentos $args -Raiz (Split-Path -Path $PSScriptRoot -Parent)
exit ([int]($codigo | Select-Object -Last 1))

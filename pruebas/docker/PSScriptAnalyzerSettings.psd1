@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # Aduana es una herramienta de consola y usa Write-Host solo para dar color cuando la salida
        # es una consola. Cuando se redirige, escribe con [Console]::Out.
        'PSAvoidUsingWriteHost',
        # Las órdenes se lanzan desde $args, no como cmdlets, así que -WhatIf y -Confirm no llegan.
        # Las destructivas piden su propia confirmación tecleada (salida preparar).
        'PSUseShouldProcessForStateChangingFunctions',
        # Los nombres están en español y la regla aplica la gramática inglesa del plural.
        'PSUseSingularNouns'
    )

    Rules        = @{
        PSUseCompatibleSyntax   = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
        # Perfil de Windows 10 (1809) con Windows PowerShell 5.1, el más parecido al PowerShell que
        # trae de serie un Windows de escritorio.
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @('win-48_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}

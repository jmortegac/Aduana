BeforeAll {
    . (Join-Path $PSScriptRoot 'Cargar.ps1')
    $pendrive = Join-Path $TestDrive 'pendrive'
    New-FixturePendrive -Raiz $pendrive
    $script = Join-Path (Join-Path $RaizRepo 'windows') 'Aduana.ps1'
    $pwsh = Get-PwshActual

    function Invoke-Capturado {
        param([string[]]$Argumentos)
        # Nombres raros a propósito: los mocks resuelven variables por ámbito dinámico y un
        # parámetro de la orden llamado igual (p. ej. -Salida) las taparía.
        $capturaSalidaPrueba = New-Object 'System.Collections.Generic.List[string]'
        $capturaErroresPrueba = New-Object 'System.Collections.Generic.List[string]'
        Mock Write-AduanaLinea { $capturaSalidaPrueba.Add($Texto) }
        Mock Write-AduanaJson { $capturaSalidaPrueba.Add($Json) }
        Mock Write-AduanaError { $capturaErroresPrueba.Add($Texto) }
        $codigo = Invoke-Aduana -Argumentos $Argumentos -Raiz $RaizRepo
        return @{ Codigo = $codigo; Salida = ($capturaSalidaPrueba -join "`n"); Errores = ($capturaErroresPrueba -join "`n") }
    }
}

Describe 'Aduana.ps1 como proceso' {
    It 'inspecciona y devuelve 2 con JSON conforme al contrato' {
        $texto = (& $pwsh -NoProfile -NonInteractive -File $script inspeccionar $pendrive --json --sin-antivirus) -join "`n"
        $LASTEXITCODE | Should -Be 2
        $r = $texto | ConvertFrom-Json
        @($r.PSObject.Properties.Name) | Should -Be @('aduana', 'orden', 'ruta', 'fecha', 'sistema', 'resumen', 'veredicto', 'hallazgos', 'antivirus', 'dispositivo')
        @($r.resumen.PSObject.Properties.Name) | Should -Be @('ficheros', 'carpetas', 'peligroso', 'sospechoso', 'informativo')
        @($r.hallazgos[0].PSObject.Properties.Name) | Should -Be @('nivel', 'regla', 'ruta', 'detalle')
        @($r.antivirus.PSObject.Properties.Name) | Should -Be @('motor', 'estado', 'detalle')
        $r.aduana | Should -Be '0.3.0'
        $r.orden | Should -Be 'inspeccionar'
        $r.sistema | Should -Be 'windows'
        $r.veredicto | Should -Be 'peligroso'
        $texto | Should -Match '"fecha": "\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z"'
        $r.antivirus.estado | Should -Be 'omitido'
        $r.dispositivo | Should -BeNullOrEmpty
        $r.resumen.peligroso | Should -Be @($r.hallazgos | Where-Object { $_.nivel -eq 'peligroso' }).Count
    }

    It 'escribe los caracteres de engaño escapados en el JSON y no en crudo' {
        $texto = (& $pwsh -NoProfile -NonInteractive -File $script inspeccionar $pendrive --json --sin-antivirus) -join "`n"
        $texto.Contains($RLO) | Should -BeFalse
        $texto | Should -Match ([regex]::Escape('foto' + [char]0x5c + 'u202egpj.exe'))
    }

    It 'enseña los nombres peligrosos con su código en el informe de texto' {
        $texto = (& $pwsh -NoProfile -NonInteractive -File $script inspeccionar $pendrive --sin-antivirus) -join "`n"
        $LASTEXITCODE | Should -Be 2
        $texto.Contains($RLO) | Should -BeFalse
        $texto | Should -Match 'U\+202E'
        $texto | Should -Match 'PELIGROSO'
        $texto | Should -Match 'Veredicto peligroso'
    }

    It 'devuelve 0 con un pendrive limpio y 1 con uno sospechoso' {
        $limpio = Join-Path $TestDrive 'limpio'
        Write-FixtureTexto (Join-Path $limpio 'notas.txt') 'hola'
        & $pwsh -NoProfile -NonInteractive -File $script inspeccionar $limpio --sin-antivirus | Out-Null
        $LASTEXITCODE | Should -Be 0
        $sospechoso = Join-Path $TestDrive 'sospechoso'
        Write-FixtureTexto (Join-Path $sospechoso 'pagina.html') '<html/>'
        & $pwsh -NoProfile -NonInteractive -File $script inspect $sospechoso --sin-antivirus | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It 'devuelve 3 ante un error de uso o una ruta que no existe' {
        # Windows PowerShell 5.1 convierte en excepción el stderr de un proceso hijo si la
        # preferencia de errores es Stop, aunque se redirija. Aquí ese stderr es lo esperado.
        $ErrorActionPreference = 'Continue'
        & $pwsh -NoProfile -NonInteractive -File $script volar 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 3
        & $pwsh -NoProfile -NonInteractive -File $script inspeccionar (Join-Path $TestDrive 'nada') 2>$null | Out-Null
        $LASTEXITCODE | Should -Be 3
    }

    It 'muestra la ayuda y la versión' {
        ((& $pwsh -NoProfile -NonInteractive -File $script ayuda) -join "`n") | Should -Match 'inspeccionar'
        $LASTEXITCODE | Should -Be 0
        (& $pwsh -NoProfile -NonInteractive -File $script --version) | Should -Be '0.3.0'
    }
}

Describe 'Inspección con la capa de sistema simulada' {
    It 'convierte las detecciones de Defender en hallazgos con ruta relativa' {
        Mock Invoke-AduanaDefender { @{ Disponible = $true; Codigo = 2; Salida = "Threat : Virus:DOS/EICAR_Test_File`n    file : $(Join-Path $pendrive 'notas.txt')`n" } }
        $r = Invoke-Capturado -Argumentos @('inspeccionar', $pendrive, '--json')
        $j = $r.Salida | ConvertFrom-Json
        $j.antivirus.motor | Should -Be 'Microsoft Defender'
        $j.antivirus.estado | Should -Be 'detecciones'
        Get-ParesHallazgos $j.hallazgos | Should -Contain 'notas.txt|antivirus'
    }

    It 'dice que el antivirus no está disponible fuera de Windows' -Skip:($env:OS -eq 'Windows_NT') {
        $r = Invoke-Capturado -Argumentos @('inspeccionar', $pendrive, '--json')
        ($r.Salida | ConvertFrom-Json).antivirus.estado | Should -Be 'no-disponible'
    }

    It 'añade los hallazgos y los datos del dispositivo' {
        Mock Get-AduanaDispositivo {
            @{
                Dispositivo        = [ordered]@{ bus = 'USB'; fabricante = 'ACME'; modelo = 'Pendrive'; sistemaFicheros = 'exFAT'; interfaces = @('Keyboard Teclado HID') }
                Interfaces         = @(@{ Clase = 'Keyboard'; Nombre = 'Teclado HID' })
                ParticionesOcultas = @()
            }
        }
        $r = Invoke-Capturado -Argumentos @('inspeccionar', $pendrive, '--json', '--sin-antivirus')
        $j = $r.Salida | ConvertFrom-Json
        @($j.dispositivo.PSObject.Properties.Name) | Should -Be @('bus', 'fabricante', 'modelo', 'sistemaFicheros', 'interfaces')
        $j.hallazgos[0].regla | Should -Be 'dispositivo-hid'
        $j.hallazgos[0].ruta | Should -Be '.'
    }

    It 'consulta VirusTotal solo por hash y gradúa el resultado' {
        $env:VT_API_KEY = 'clave-de-prueba'
        try {
            Mock Get-AduanaVirusTotal { @{ Encontrado = $true; Maliciosos = 5 } }
            Mock Wait-AduanaPausa { }
            $limpio = Join-Path $TestDrive 'vt'
            Write-FixtureBytes (Join-Path $limpio 'programa.exe') (Get-BytesMz)
            $r = Invoke-Capturado -Argumentos @('inspeccionar', $limpio, '--json', '--sin-antivirus', '--virustotal')
            Get-ParesHallazgos ($r.Salida | ConvertFrom-Json).hallazgos | Should -Contain 'programa.exe|virustotal'
            Should -Invoke Get-AduanaVirusTotal -Times 1 -Exactly -ParameterFilter { $Hash -match '^[0-9a-f]{64}$' }
        }
        finally {
            Remove-Item Env:\VT_API_KEY
        }
    }

    It 'pide la clave de VirusTotal antes de empezar' {
        $r = Invoke-Capturado -Argumentos @('inspeccionar', $pendrive, '--virustotal')
        $r.Codigo | Should -Be 3
        $r.Errores | Should -Match 'VT_API_KEY'
    }
}

Describe 'Copia con marca de origen' {
    BeforeEach {
        $destino = Join-Path $TestDrive ("copia-" + [Guid]::NewGuid().ToString('N'))
        Mock Get-AduanaSistemaFicheros { 'NTFS' }
        Mock Set-AduanaMarcaOrigen { $true }
    }

    It 'copia lo que no es peligroso, marca cada fichero y deja fuera el resto' {
        $r = Invoke-Capturado -Argumentos @('copiar', $pendrive, $destino, '--json')
        $r.Codigo | Should -Be 0 -Because "copiar dijo: $($r.Salida) $($r.Errores)"
        $j = $r.Salida | ConvertFrom-Json
        @($j.PSObject.Properties.Name) | Should -Be @('aduana', 'orden', 'origen', 'destino', 'fecha', 'sistema', 'copiados', 'marcados', 'omitidos', 'avisos')
        $j.marcados | Should -Be $j.copiados
        Test-Path (Join-Path $destino 'notas.txt') | Should -BeTrue
        Test-Path (Join-Path (Join-Path $destino 'Fotos') 'vacaciones.jpg') | Should -BeTrue
        Test-Path (Join-Path $destino 'pagina.html') | Should -BeTrue
        Test-Path (Join-Path $destino 'factura.pdf.exe') | Should -BeFalse
        Test-Path (Join-Path $destino 'foto.jpg') | Should -BeFalse
        Test-Path (Join-Path $destino '.DS_Store') | Should -BeFalse
        Test-Path (Join-Path $destino 'Programa.app') | Should -BeFalse
        Test-Path (Join-Path $destino 'enlace') | Should -BeFalse
        @($j.omitidos | ForEach-Object { $_.ruta }) | Should -Contain 'factura.pdf.exe'
        $enlaceEnPendrive = Get-Item -LiteralPath (Join-Path $pendrive 'enlace') -Force -ErrorAction SilentlyContinue
        @($j.omitidos | ForEach-Object { $_.ruta }) | Should -Contain 'enlace' -Because "omitidos: $(@($j.omitidos | ForEach-Object { $_.ruta }) -join ' | '); en el pendrive: $(if ($enlaceEnPendrive) { $enlaceEnPendrive.Attributes } else { 'no existe' })"
        Should -Invoke Set-AduanaMarcaOrigen -Times $j.copiados -Exactly
    }

    It 'con --incluir-peligrosos copia también lo peligroso y los paquetes enteros' {
        $r = Invoke-Capturado -Argumentos @('copiar', $pendrive, $destino, '--incluir-peligrosos', '--json')
        $r.Codigo | Should -Be 0
        Test-Path (Join-Path $destino 'factura.pdf.exe') | Should -BeTrue
        Test-Path (Join-Path (Join-Path (Join-Path (Join-Path $destino 'Programa.app') 'Contents') 'MacOS') 'Programa') | Should -BeTrue
    }

    It 'nunca sobrescribe y renombra con un número' {
        Write-FixtureTexto (Join-Path $destino 'notas.txt') 'ya estaba'
        $null = Invoke-Capturado -Argumentos @('copiar', $pendrive, $destino)
        [IO.File]::ReadAllText((Join-Path $destino 'notas.txt')) | Should -Be 'ya estaba'
        Test-Path (Join-Path $destino 'notas (2).txt') | Should -BeTrue
    }

    It 'avisa si el destino no admite la marca de origen' {
        Mock Get-AduanaSistemaFicheros { 'exFAT' }
        $j = (Invoke-Capturado -Argumentos @('copiar', $pendrive, $destino, '--json')).Salida | ConvertFrom-Json
        $j.marcados | Should -Be 0
        $j.avisos[0] | Should -Match 'exFAT'
        Should -Invoke Set-AduanaMarcaOrigen -Times 0 -Exactly
    }

    It 'no copia nada de dentro de una carpeta peligrosa omitida' {
        $origen = Join-Path $TestDrive ("carpeta-rlo-" + [Guid]::NewGuid().ToString('N'))
        $carpeta = "carpeta$($RLO)fdp"
        Write-FixtureTexto (Join-Path (Join-Path $origen $carpeta) 'notas.txt') 'dentro'
        Write-FixtureTexto (Join-Path (Join-Path (Join-Path $origen $carpeta) 'sub') 'mas.txt') 'dentro'
        Write-FixtureTexto (Join-Path $origen 'fuera.txt') 'fuera'
        $j = (Invoke-Capturado -Argumentos @('copiar', $origen, $destino, '--json')).Salida | ConvertFrom-Json
        @($j.omitidos | ForEach-Object { $_.ruta }) | Should -Contain $carpeta
        Test-Path -LiteralPath (Join-Path $destino $carpeta) | Should -BeFalse
        @(Get-ChildItem -LiteralPath $destino -Recurse -Force | ForEach-Object { $_.Name }) | Should -Be @('fuera.txt')
        $j.copiados | Should -Be 1
    }

    It 'devuelve 3 si no se pudo poner la marca de origen' {
        Mock Set-AduanaMarcaOrigen { $false }
        $r = Invoke-Capturado -Argumentos @('copiar', $pendrive, $destino, '--json')
        $r.Codigo | Should -Be 3
        ($r.Salida | ConvertFrom-Json).avisos.Count | Should -BeGreaterThan 0
    }

    It 'devuelve 3 si el destino no admite la marca' {
        Mock Get-AduanaSistemaFicheros { 'exFAT' }
        (Invoke-Capturado -Argumentos @('copiar', $pendrive, $destino)).Codigo | Should -Be 3
    }

    It 'sigue copiando el resto si falla un fichero, y lo avisa con código 3' {
        $origen = Join-Path $TestDrive ("fallo-" + [Guid]::NewGuid().ToString('N'))
        Write-FixtureTexto (Join-Path (Join-Path $origen 'a') 'x.txt') 'x'
        Write-FixtureTexto (Join-Path $origen 'z.txt') 'z'
        # Un fichero donde debería ir la carpeta «a» hace fallar la copia de a/x.txt.
        Write-FixtureTexto (Join-Path $destino 'a') 'estorbo'
        $r = Invoke-Capturado -Argumentos @('copiar', $origen, $destino, '--json')
        $r.Codigo | Should -Be 3
        Test-Path (Join-Path $destino 'z.txt') | Should -BeTrue
        ($r.Salida | ConvertFrom-Json).avisos.Count | Should -BeGreaterThan 0
    }

    It 'con --incluir-peligrosos no sigue enlaces dentro de un paquete' {
        $origen = Join-Path $TestDrive ("paquete-" + [Guid]::NewGuid().ToString('N'))
        $contenido = Join-Path (Join-Path $origen 'Programa.app') 'Contents'
        Write-FixtureTexto (Join-Path $contenido 'Info.plist') '<plist/>'
        $fuera = Join-Path $TestDrive ("fuera-" + [Guid]::NewGuid().ToString('N'))
        Write-FixtureTexto (Join-Path $fuera 'secreto.txt') 'secreto'
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $contenido 'enlace.txt') -Target (Join-Path $fuera 'secreto.txt')
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $contenido 'carpeta') -Target $fuera
        $null = Invoke-Capturado -Argumentos @('copiar', $origen, $destino, '--incluir-peligrosos')
        $copia = Join-Path (Join-Path $destino 'Programa.app') 'Contents'
        Test-Path (Join-Path $copia 'Info.plist') | Should -BeTrue
        Test-Path (Join-Path $copia 'enlace.txt') | Should -BeFalse
        Test-Path (Join-Path $copia 'carpeta') | Should -BeFalse
    }

    It 'se niega a copiar dentro del propio origen' {
        (Invoke-Capturado -Argumentos @('copiar', $pendrive, (Join-Path $pendrive 'dentro'))).Codigo | Should -Be 3
    }

    It 'exige Dangerzone para desinfectar' {
        Mock Find-AduanaDangerzone { $null }
        (Invoke-Capturado -Argumentos @('copiar', $pendrive, $destino, '--desinfectar')).Codigo | Should -Be 3
    }

    It 'convierte los documentos con Dangerzone al desinfectar' {
        Mock Find-AduanaDangerzone { 'dangerzone-cli' }
        Mock Invoke-AduanaDangerzone { [IO.File]::WriteAllText($Destino, '%PDF'); 0 }
        $origen = Join-Path $TestDrive 'docs'
        Write-FixtureTexto (Join-Path $origen 'informe.pdf') '%PDF-1.4'
        Write-FixtureTexto (Join-Path $origen 'notas.txt') 'hola'
        $r = Invoke-Capturado -Argumentos @('copiar', $origen, $destino, '--desinfectar')
        $r.Codigo | Should -Be 0
        Test-Path (Join-Path $destino 'informe-seguro.pdf') | Should -BeTrue
        Test-Path (Join-Path $destino 'informe.pdf') | Should -BeFalse
        Test-Path (Join-Path $destino 'notas.txt') | Should -BeTrue
    }
}

Describe 'Preparar y restaurar el equipo' {
    BeforeEach {
        $env:ADUANA_ESTADO = Join-Path $TestDrive ("estado-" + [Guid]::NewGuid().ToString('N'))
        $registro = @{}
        Mock Test-AduanaWindows { $true }
        Mock Test-AduanaAdmin { $true }
        Mock Get-AduanaValorRegistro {
            if ($Nombre -eq 'NoDriveTypeAutoRun' -and $Ruta -like 'HKCU:*') { return @{ Existe = $true; Valor = 145; Tipo = 'DWord' } }
            return @{ Existe = $false; Valor = $null; Tipo = $null }
        }
        Mock Set-AduanaValorRegistro { $registro["$Ruta|$Nombre"] = $Valor }
        Mock Remove-AduanaValorRegistro { $registro["$Ruta|$Nombre"] = 'borrado' }
        Mock Invoke-AduanaMountvol { 0 }
        Mock Test-AduanaClaveRegistro { $true }
        Mock Remove-AduanaClaveRegistroVacia { }
    }
    AfterEach {
        Remove-Item Env:\ADUANA_ESTADO
    }

    It 'guarda el estado previo, aplica los ajustes y los restaura' {
        (Invoke-Capturado -Argumentos @('preparar-equipo', '--sin-automontaje')).Codigo | Should -Be 0
        $estado = [IO.File]::ReadAllText((Join-Path $env:ADUANA_ESTADO 'estado-equipo.json')) | ConvertFrom-Json
        @($estado.valores).Count | Should -Be 4
        $estado.valores[0].existe | Should -BeTrue
        $estado.valores[0].valor | Should -Be 145
        $estado.automontaje | Should -BeTrue
        Should -Invoke Set-AduanaValorRegistro -Times 4 -Exactly
        Should -Invoke Invoke-AduanaMountvol -Times 1 -Exactly -ParameterFilter { $Activar -eq $false }
        $registro['HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}|Deny_Execute'] | Should -Be 1

        (Invoke-Capturado -Argumentos @('restaurar-equipo')).Codigo | Should -Be 0
        $registro['HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer|NoDriveTypeAutoRun'] | Should -Be 145
        Should -Invoke Remove-AduanaValorRegistro -Times 3 -Exactly
        Should -Invoke Invoke-AduanaMountvol -Times 1 -Exactly -ParameterFilter { $Activar -eq $true }
        Test-Path (Join-Path $env:ADUANA_ESTADO 'estado-equipo.json') | Should -BeFalse
    }

    It 'borra al restaurar las claves que creó, de la más profunda a la menos, y nunca las que existían' {
        $politicas = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\RemovableStorageDevices'
        $guid = "$politicas\{53f5630d-b6bf-11d0-94f2-00a0c91efb8b}"
        $autoplay = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\AutoplayHandlers'
        Mock Test-AduanaClaveRegistro { -not ($Ruta -eq $politicas -or $Ruta -eq $guid -or $Ruta -eq $autoplay) }
        $borradas = New-Object 'System.Collections.Generic.List[string]'
        Mock Remove-AduanaClaveRegistroVacia { $borradas.Add($Ruta) }
        $null = Invoke-Capturado -Argumentos @('preparar-equipo')
        $estado = [IO.File]::ReadAllText((Join-Path $env:ADUANA_ESTADO 'estado-equipo.json')) | ConvertFrom-Json
        @($estado.clavesCreadas).Count | Should -Be 3
        (Invoke-Capturado -Argumentos @('restaurar-equipo')).Codigo | Should -Be 0
        $borradas.Count | Should -Be 3
        $borradas.IndexOf($guid) | Should -BeLessThan $borradas.IndexOf($politicas)
        $borradas | Should -Contain $autoplay
        $borradas | Should -Not -Contain 'HKLM:\SOFTWARE\Policies\Microsoft\Windows'
    }

    It 'restaura un estado antiguo sin lista de claves creadas' {
        [void][IO.Directory]::CreateDirectory($env:ADUANA_ESTADO)
        [IO.File]::WriteAllText((Join-Path $env:ADUANA_ESTADO 'estado-equipo.json'), '{"valores":[],"automontaje":false}')
        (Invoke-Capturado -Argumentos @('restaurar-equipo')).Codigo | Should -Be 0
        Should -Invoke Remove-AduanaClaveRegistroVacia -Times 0 -Exactly
    }

    It 'una segunda preparación conserva el estado original' {
        $null = Invoke-Capturado -Argumentos @('preparar-equipo')
        Mock Get-AduanaValorRegistro { @{ Existe = $true; Valor = 255; Tipo = 'DWord' } }
        $null = Invoke-Capturado -Argumentos @('preparar-equipo')
        $estado = [IO.File]::ReadAllText((Join-Path $env:ADUANA_ESTADO 'estado-equipo.json')) | ConvertFrom-Json
        $estado.valores[0].valor | Should -Be 145
        $estado.valores[1].existe | Should -BeFalse
    }

    It 'exige administrador' {
        Mock Test-AduanaAdmin { $false }
        (Invoke-Capturado -Argumentos @('preparar-equipo')).Codigo | Should -Be 3
        Should -Invoke Set-AduanaValorRegistro -Times 0 -Exactly
    }

    It 'no restaura si nunca se preparó' {
        (Invoke-Capturado -Argumentos @('restaurar-equipo')).Codigo | Should -Be 3
    }
}

Describe 'Montar y preparar discos' {
    BeforeEach {
        Mock Test-AduanaWindows { $true }
        Mock Invoke-AduanaFormateo { 'F' }
        Mock Set-AduanaDiscoSoloLectura { $true }
        Mock Add-AduanaLetrasDisco { , @('F') }
    }

    It 'se niega a tocar <Caso>' -TestCases @(
        @{ Caso = 'un disco SATA'; Disco = [pscustomobject]@{ Number = 1; BusType = 'SATA'; IsSystem = $false; IsBoot = $false; FriendlyName = 'SSD'; Size = 1 } }
        @{ Caso = 'el disco del sistema aunque sea USB'; Disco = [pscustomobject]@{ Number = 1; BusType = 'USB'; IsSystem = $true; IsBoot = $false; FriendlyName = 'USB'; Size = 1 } }
        @{ Caso = 'el disco de arranque'; Disco = [pscustomobject]@{ Number = 1; BusType = 'USB'; IsSystem = $false; IsBoot = $true; FriendlyName = 'USB'; Size = 1 } }
        @{ Caso = 'un disco que no existe'; Disco = $null }
    ) {
        param($Disco)
        Mock Get-AduanaDisco { $Disco }
        (Invoke-Capturado -Argumentos @('salida', 'preparar', '1', '--si')).Codigo | Should -Be 3
        (Invoke-Capturado -Argumentos @('montar', '1')).Codigo | Should -Be 3
        Should -Invoke Invoke-AduanaFormateo -Times 0 -Exactly
        Should -Invoke Set-AduanaDiscoSoloLectura -Times 0 -Exactly
    }

    It 'cancela si el número tecleado no coincide' {
        Mock Get-AduanaDisco { [pscustomobject]@{ Number = 4; BusType = 'USB'; IsSystem = $false; IsBoot = $false; FriendlyName = 'Kingston'; Size = 16GB } }
        Mock Read-AduanaConfirmacion { '5' }
        (Invoke-Capturado -Argumentos @('out', 'prepare', '4')).Codigo | Should -Be 3
        Should -Invoke Invoke-AduanaFormateo -Times 0 -Exactly
    }

    It 'formatea si el número tecleado coincide' {
        Mock Get-AduanaDisco { [pscustomobject]@{ Number = 4; BusType = 'USB'; IsSystem = $false; IsBoot = $false; FriendlyName = 'Kingston'; Size = 16GB } }
        Mock Read-AduanaConfirmacion { ' 4 ' }
        (Invoke-Capturado -Argumentos @('salida', 'preparar', '4', '--nombre', 'PRESTAMO', '--borrado-completo')).Codigo | Should -Be 0
        Should -Invoke Invoke-AduanaFormateo -Times 1 -Exactly -ParameterFilter { $Numero -eq 4 -and $Nombre -eq 'PRESTAMO' -and $Completo -eq $true }
    }

    It 'acepta un disco virtual para las pruebas en CI' {
        Mock Get-AduanaDisco { [pscustomobject]@{ Number = 7; BusType = 'File Backed Virtual'; IsSystem = $false; IsBoot = $false; FriendlyName = 'VHD'; Size = 64MB } }
        (Invoke-Capturado -Argumentos @('salida', 'preparar', '7', '--si')).Codigo | Should -Be 0
        (Invoke-Capturado -Argumentos @('montar', '7')).Codigo | Should -Be 0
        Should -Invoke Set-AduanaDiscoSoloLectura -Times 1 -Exactly
    }

    It 'rechaza nombres de volumen no válidos' {
        Mock Get-AduanaDisco { [pscustomobject]@{ Number = 4; BusType = 'USB'; IsSystem = $false; IsBoot = $false; FriendlyName = 'K'; Size = 1 } }
        (Invoke-Capturado -Argumentos @('salida', 'preparar', '4', '--si', '--nombre', 'NOMBREDEMASIADOLARGO')).Codigo | Should -Be 3
        (Invoke-Capturado -Argumentos @('salida', 'preparar', '4', '--si', '--nombre', 'A:B')).Codigo | Should -Be 3
        (Invoke-Capturado -Argumentos @('salida', 'preparar', '4', '--si', '--nombre', 'Préstamo')).Codigo | Should -Be 3
    }

    It 'no monta si Windows no deja poner el disco en solo lectura' {
        Mock Get-AduanaDisco { [pscustomobject]@{ Number = 4; BusType = 'USB'; IsSystem = $false; IsBoot = $false; FriendlyName = 'K'; Size = 1 } }
        Mock Set-AduanaDiscoSoloLectura { $false }
        $r = Invoke-Capturado -Argumentos @('montar', '4')
        $r.Codigo | Should -Be 3
        $r.Errores | Should -Match 'solo lectura'
        Should -Invoke Add-AduanaLetrasDisco -Times 0 -Exactly
    }

    It 'rechaza un número de disco que no es un número' {
        (Invoke-Capturado -Argumentos @('montar', 'E:')).Codigo | Should -Be 3
    }
}

Describe 'Centinela, Sandbox y cifrado' {
    It 'el código C# del centinela compila' {
        if (-not ('AduanaCentinela' -as [type])) {
            Add-Type -TypeDefinition (Get-AduanaCodigoCentinela) -Language CSharp
        }
        [AduanaCentinela]::IdTeclado('\\?\HID#VID_046d&PID_c31c&MI_00#7&1a2b#{884b96c3-56ef-11d1-bc8c-00a0c91405dd}') | Should -Be 'VID_046D&PID_C31C'
        [AduanaCentinela]::IdTeclado('ACPI\PNP0303\4&1') | Should -BeNullOrEmpty
    }

    It 'extrae VID y PID igual en PowerShell' {
        Get-AduanaIdTeclado -Texto 'HID\VID_046d&PID_c31c&MI_00\7&1' | Should -Be 'VID_046D&PID_C31C'
        Get-AduanaIdTeclado -Texto 'ACPI\PNP0303' | Should -BeNullOrEmpty
    }

    It 'aprende los teclados presentes' {
        $env:ADUANA_ESTADO = Join-Path $TestDrive 'estado-centinela'
        try {
            Mock Test-AduanaWindows { $true }
            Mock Get-AduanaTecladosPresentes { , @('VID_046D&PID_C31C') }
            (Invoke-Capturado -Argumentos @('centinela', '--aprender')).Codigo | Should -Be 0
            [IO.File]::ReadAllLines((Join-Path $env:ADUANA_ESTADO 'teclados-conocidos.txt')) | Should -Be @('VID_046D&PID_C31C')
        }
        finally {
            Remove-Item Env:\ADUANA_ESTADO
        }
    }

    It 'devuelve 2 si el centinela se dispara y pasa los teclados conocidos' {
        $env:ADUANA_ESTADO = Join-Path $TestDrive 'estado-centinela-2'
        try {
            Mock Test-AduanaWindows { $true }
            Mock Get-AduanaTecladosPresentes { , @('VID_1111&PID_2222') }
            Mock Start-AduanaCentinela { @{ Disparado = $true; Dispositivo = 'HID#VID_DEAD&PID_BEEF' } }
            (Invoke-Capturado -Argumentos @('centinela', '--durante', '10')).Codigo | Should -Be 2
            Should -Invoke Start-AduanaCentinela -ParameterFilter { $Segundos -eq 10 -and $Conocidos -contains 'VID_1111&PID_2222' }
            Mock Start-AduanaCentinela { @{ Disparado = $false; Dispositivo = $null } }
            (Invoke-Capturado -Argumentos @('centinela')).Codigo | Should -Be 0
            (Invoke-Capturado -Argumentos @('centinela', '--durante', '2')).Codigo | Should -Be 3
        }
        finally {
            Remove-Item Env:\ADUANA_ESTADO
        }
    }

    It 'genera una configuración de Sandbox sin red y en solo lectura' {
        [xml]$xml = New-AduanaConfiguracionSandbox -Ruta 'E:\Fotos & vídeos'
        $xml.Configuration.Networking | Should -Be 'Disable'
        $xml.Configuration.ClipboardRedirection | Should -Be 'Disable'
        $xml.Configuration.MappedFolders.MappedFolder.ReadOnly | Should -Be 'true'
        $xml.Configuration.MappedFolders.MappedFolder.HostFolder | Should -Be 'E:\Fotos & vídeos'
    }

    It 'explica que falta Windows Sandbox' {
        Mock Find-AduanaSandbox { $null }
        $r = Invoke-Capturado -Argumentos @('sandbox', $pendrive)
        $r.Codigo | Should -Be 3
        $r.Errores | Should -Match 'Pro'
    }

    It 'abre Windows Sandbox con la configuración' {
        Mock Find-AduanaSandbox { 'WindowsSandbox.exe' }
        Mock Start-AduanaSandbox { }
        (Invoke-Capturado -Argumentos @('sandbox', $pendrive)).Codigo | Should -Be 0
        Should -Invoke Start-AduanaSandbox -Times 1 -Exactly -ParameterFilter { $Configuracion -like '*.wsb' }
    }

    It 'exige 7-Zip para cifrar' {
        Mock Find-Aduana7z { $null }
        (Invoke-Capturado -Argumentos @('salida', 'cifrar', $pendrive)).Codigo | Should -Be 3
    }

    It 'cifra con 7-Zip sin sobrescribir' {
        Mock Find-Aduana7z { '7z' }
        Mock Invoke-Aduana7z { 0 }
        $carpeta = Join-Path $TestDrive 'secreto'
        Write-FixtureTexto (Join-Path $carpeta 'a.txt') 'x'
        $r = Invoke-Capturado -Argumentos @('salida', 'cifrar', $carpeta)
        $r.Errores | Should -BeNullOrEmpty
        $r.Codigo | Should -Be 0
        Should -Invoke Invoke-Aduana7z -ParameterFilter { $Salida -like '*secreto.7z' }
        Write-FixtureTexto "$carpeta.7z" 'ya existe'
        (Invoke-Capturado -Argumentos @('salida', 'cifrar', $carpeta)).Codigo | Should -Be 3
    }
}

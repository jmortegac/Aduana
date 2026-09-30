BeforeDiscovery {
    # -Skip se evalúa al descubrir las pruebas, antes de BeforeAll.
    $haySsh = [bool](Get-Command -Name ssh-keygen -CommandType Application -ErrorAction SilentlyContinue)
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'Cargar.ps1')
    $ssh = Find-AduanaSshKeygen

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

    function New-VolumenFirmable {
        param([string]$Raiz)
        Write-FixtureTexto (Join-Path $Raiz 'b.txt') 'bbb'
        Write-FixtureTexto (Join-Path $Raiz 'a.txt') 'aaa'
        Write-FixtureTexto (Join-Path $Raiz '.oculto') 'oculto'
        Write-FixtureTexto (Join-Path (Join-Path $Raiz 'Z') 'c.txt') 'ccc'
        Write-FixtureTexto (Join-Path $Raiz ('cafe' + [char]0x0301 + '.txt')) 'NFD'
        Write-FixtureTexto (Join-Path $Raiz '.DS_Store') 'basura'
        Write-FixtureBytes (Join-Path $Raiz '._a.txt') ([byte[]]@(0x00, 0x05, 0x16, 0x07))
    }
}

Describe 'Formato del manifiesto' {
    It 'genera el texto con cabecera, hashes en minúsculas, rutas NFC y orden por bytes' {
        $raiz = Join-Path $TestDrive 'formato'
        New-VolumenFirmable -Raiz $raiz
        $f = Get-AduanaFicherosFirmables -Raiz $raiz -Reglas $Reglas
        $hashes = Get-AduanaHashesActuales -Ficheros $f.Ficheros
        $texto = New-AduanaManifiestoTexto -Hashes $hashes -Fecha '2026-09-30T12:00:00Z'
        $lineas = $texto.Split("`n")
        $lineas[0] | Should -BeExactly '# Aduana manifiesto v1'
        $lineas[1] | Should -BeExactly '# fecha: 2026-09-30T12:00:00Z'
        $texto.EndsWith("`n") | Should -BeTrue
        $texto.Contains("`r") | Should -BeFalse
        $rutas = @($lineas | Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object { $_.Substring(66) })
        $rutas | Should -Be @('.oculto', 'Z/c.txt', 'a.txt', 'b.txt', ('caf' + [char]0x00e9 + '.txt'))
        $lineas[2] | Should -Match '^[0-9a-f]{64}  \.oculto$'
        $texto | Should -Not -Match 'DS_Store'
        $texto | Should -Not -Match '\._a'
    }

    It 'ordena por bytes UTF-8 y no por UTF-16' {
        # U+FF21 (A de ancho completo) va antes que un carácter fuera del plano básico en UTF-16,
        # pero después en UTF-8.
        $fuera = [char]::ConvertFromUtf32(0x1F600)
        $ancha = [string][char]0xFF21
        (Compare-AduanaUtf8 $ancha $fuera) | Should -BeLessThan 0
        (Compare-AduanaUtf8 'B' 'a') | Should -BeLessThan 0
    }

    It 'lee un manifiesto y detecta cada tipo de cambio' {
        $a = 'a' * 64
        $b = 'b' * 64
        $esperado = ConvertFrom-AduanaManifiesto -Texto "# Aduana manifiesto v1`n# fecha: x`n$a  uno.txt`n$a  dos.txt`n"
        $actual = New-Object 'System.Collections.Generic.Dictionary[string,string]'
        $actual['uno.txt'] = $b
        $actual['tres.txt'] = $a
        $cambios = Compare-AduanaManifiesto -Esperado $esperado -Actual $actual -Enlaces @('enlace')
        @($cambios | ForEach-Object { "$($_.tipo)|$($_.ruta)" }) | Should -Be @('ausente|dos.txt', 'añadido|enlace', 'añadido|tres.txt', 'modificado|uno.txt')
    }

    It 'rechaza un manifiesto dañado' {
        $codigo = $null
        try { $null = ConvertFrom-AduanaManifiesto -Texto "zzz  uno.txt`n" } catch { $codigo = $_.Exception.Data['AduanaCodigo'] }
        $codigo | Should -Be 2
    }

    It 'lee claves públicas y ficheros de firmantes' {
        $c = Get-AduanaClavePublica -Texto 'ssh-ed25519 AAAAC3Nza comentario'
        $c.Tipo | Should -Be 'ssh-ed25519'
        $f = Join-Path $TestDrive 'firmantes'
        Write-FixtureTexto $f "# comentario`nana@casa namespaces=`"aduana`" ssh-ed25519 AAAAC3Nza`nluis ssh-rsa BBBB`n"
        Find-AduanaFirmante -Fichero $f -Tipo 'ssh-ed25519' -Material 'AAAAC3Nza' | Should -Be 'ana@casa'
        Find-AduanaFirmante -Fichero $f -Tipo 'ssh-ed25519' -Material 'OTRA' | Should -BeNullOrEmpty
    }
}

Describe 'Firmar y verificar con ssh-keygen de verdad' {
    BeforeAll {
        $env:ADUANA_ESTADO = Join-Path $TestDrive 'estado'
        $clave = Join-Path $TestDrive 'clave'
        & $ssh -q -t ed25519 -N '' -C 'prueba' -f $clave | Out-Null
    }
    AfterAll {
        Remove-Item Env:\ADUANA_ESTADO -ErrorAction SilentlyContinue
    }
    BeforeEach {
        $vol = Join-Path $TestDrive ("vol-" + [Guid]::NewGuid().ToString('N'))
        New-VolumenFirmable -Raiz $vol
    }

    It 'firma, y verifica como firmante desconocido hasta que se confía en él' -Skip:(-not $haySsh) {
        (Invoke-Capturado -Argumentos @('salida', 'firmar', $vol, '--clave', $clave)).Codigo | Should -Be 0
        Test-Path (Join-Path $vol 'ADUANA-MANIFIESTO.txt.sig') | Should -BeTrue
        Test-Path (Join-Path $vol 'ADUANA-CLAVE.pub') | Should -BeTrue
        $bytes = [IO.File]::ReadAllBytes((Join-Path $vol 'ADUANA-MANIFIESTO.txt'))
        $bytes[0] | Should -Be ([byte][char]'#')

        $r = Invoke-Capturado -Argumentos @('verificar', $vol, '--json')
        $r.Codigo | Should -Be 1
        $j = $r.Salida | ConvertFrom-Json
        @($j.PSObject.Properties.Name) | Should -Be @('aduana', 'orden', 'ruta', 'fecha', 'sistema', 'firma', 'cambios', 'veredicto')
        @($j.firma.PSObject.Properties.Name) | Should -Be @('estado', 'firmante', 'huella')
        $j.firma.estado | Should -Be 'firmante-desconocido'
        $j.firma.huella | Should -Match '^SHA256:'
        $j.veredicto | Should -Be 'intacto'

        (Invoke-Capturado -Argumentos @('verificar', $vol, '--confiar', 'Ana')).Codigo | Should -Be 0
        $j = (Invoke-Capturado -Argumentos @('verificar', $vol, '--json')).Salida | ConvertFrom-Json
        $j.firma.estado | Should -Be 'valida'
        $j.firma.firmante | Should -Be 'Ana'
    }

    It 'detecta un fichero cambiado, uno borrado, uno añadido y un enlace' -Skip:(-not $haySsh) {
        $null = Invoke-Capturado -Argumentos @('salida', 'firmar', $vol, '--clave', $clave)
        [IO.File]::WriteAllText((Join-Path $vol 'a.txt'), 'AAA')
        Remove-Item (Join-Path $vol 'b.txt')
        Write-FixtureTexto (Join-Path $vol 'nuevo.txt') 'nuevo'
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $vol 'enlace') -Target '/etc'
        Write-FixtureTexto (Join-Path $vol '.DS_Store') 'otra basura'
        $r = Invoke-Capturado -Argumentos @('verificar', $vol, '--json')
        $r.Codigo | Should -Be 2
        $j = $r.Salida | ConvertFrom-Json
        $j.veredicto | Should -Be 'alterado'
        @($j.cambios | ForEach-Object { "$($_.tipo)|$($_.ruta)" }) | Should -Be @('modificado|a.txt', 'ausente|b.txt', 'añadido|enlace', 'añadido|nuevo.txt')
    }

    It 'da la firma por inválida si se toca el manifiesto' -Skip:(-not $haySsh) {
        $null = Invoke-Capturado -Argumentos @('salida', 'firmar', $vol, '--clave', $clave)
        $m = Join-Path $vol 'ADUANA-MANIFIESTO.txt'
        [IO.File]::AppendAllText($m, ('0' * 64) + "  colado.txt`n")
        Write-FixtureTexto (Join-Path $vol 'colado.txt') 'colado'
        $j = (Invoke-Capturado -Argumentos @('verificar', $vol, '--json')).Salida | ConvertFrom-Json
        $j.firma.estado | Should -Be 'invalida'
        $j.veredicto | Should -Be 'alterado'
    }

    It 'da la firma por inválida si falta' -Skip:(-not $haySsh) {
        $null = Invoke-Capturado -Argumentos @('salida', 'firmar', $vol, '--clave', $clave)
        Remove-Item (Join-Path $vol 'ADUANA-MANIFIESTO.txt.sig')
        (Invoke-Capturado -Argumentos @('verificar', $vol)).Codigo | Should -Be 2
    }

    It 'no deja rastro en el volumen si ssh-keygen no puede firmar' -Skip:(-not $haySsh) {
        $abierta = Join-Path $TestDrive ("abierta-" + [Guid]::NewGuid().ToString('N'))
        Copy-Item $clave $abierta
        Copy-Item "$clave.pub" "$abierta.pub"
        & chmod 644 $abierta
        $r = Invoke-Capturado -Argumentos @('salida', 'firmar', $vol, '--clave', $abierta)
        $r.Codigo | Should -Be 3
        foreach ($n in (Get-AduanaNombresManifiesto)) {
            Test-Path -LiteralPath (Join-Path $vol $n) | Should -BeFalse
        }
    }

    It 'conserva el manifiesto anterior si una nueva firma falla' -Skip:(-not $haySsh) {
        $null = Invoke-Capturado -Argumentos @('salida', 'firmar', $vol, '--clave', $clave)
        $antes = [IO.File]::ReadAllText((Join-Path $vol 'ADUANA-MANIFIESTO.txt'))
        Write-FixtureTexto (Join-Path $vol 'nuevo.txt') 'nuevo'
        $abierta = Join-Path $TestDrive ("abierta-" + [Guid]::NewGuid().ToString('N'))
        Copy-Item $clave $abierta
        Copy-Item "$clave.pub" "$abierta.pub"
        & chmod 644 $abierta
        (Invoke-Capturado -Argumentos @('salida', 'firmar', $vol, '--clave', $abierta)).Codigo | Should -Be 3
        [IO.File]::ReadAllText((Join-Path $vol 'ADUANA-MANIFIESTO.txt')) | Should -BeExactly $antes
        Test-Path (Join-Path $vol 'ADUANA-MANIFIESTO.txt.sig') | Should -BeTrue
        Remove-Item (Join-Path $vol 'nuevo.txt')
        # La clave puede estar ya entre los firmantes por otra prueba; lo que importa es que el
        # manifiesto anterior sigue verificando intacto.
        ((Invoke-Capturado -Argumentos @('verificar', $vol, '--json')).Salida | ConvertFrom-Json).veredicto | Should -Be 'intacto'
    }

    It 'se niega a firmar con enlaces simbólicos' -Skip:(-not $haySsh) {
        $null = New-Item -ItemType SymbolicLink -Path (Join-Path $vol 'enlace') -Target '/etc'
        $r = Invoke-Capturado -Argumentos @('salida', 'firmar', $vol, '--clave', $clave)
        $r.Codigo | Should -Be 3
        Test-Path (Join-Path $vol 'ADUANA-MANIFIESTO.txt') | Should -BeFalse
    }

    It 'devuelve 3 sin manifiesto o sin clave pública' -Skip:(-not $haySsh) {
        (Invoke-Capturado -Argumentos @('verificar', $vol)).Codigo | Should -Be 3
        $sinPublica = Join-Path $TestDrive 'solo-privada'
        Copy-Item $clave $sinPublica
        (Invoke-Capturado -Argumentos @('salida', 'firmar', $vol, '--clave', $sinPublica)).Codigo | Should -Be 3
        (Invoke-Capturado -Argumentos @('salida', 'firmar', $vol)).Codigo | Should -Be 3
    }

    It 'rechaza un nombre de firmante con espacios' -Skip:(-not $haySsh) {
        $null = Invoke-Capturado -Argumentos @('salida', 'firmar', $vol, '--clave', $clave)
        (Invoke-Capturado -Argumentos @('verificar', $vol, '--confiar', 'Ana López')).Codigo | Should -Be 3
    }
}

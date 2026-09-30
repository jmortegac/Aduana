BeforeAll {
    . (Join-Path $PSScriptRoot 'Cargar.ps1')
}

Describe 'JSON propio' {
    It 'serializa tipos básicos y respeta el orden de las claves' {
        $valor = [ordered]@{ b = 1; a = 'x'; c = $true; d = $null; e = @(); f = [ordered]@{} ; g = 2.5 }
        $json = ConvertTo-AduanaJson -Valor $valor
        $objeto = $json | ConvertFrom-Json
        @($objeto.PSObject.Properties.Name) | Should -Be @('b', 'a', 'c', 'd', 'e', 'f', 'g')
        $objeto.b | Should -Be 1
        $objeto.c | Should -BeTrue
        $objeto.d | Should -BeNullOrEmpty
        $json | Should -Match '"e": \[\]'
        $json | Should -Match '"f": \{\}'
        $json | Should -Match '"g": 2.5'
    }

    It 'mantiene como array una lista de un solo elemento' {
        $lista = New-Object 'System.Collections.Generic.List[object]'
        $lista.Add([ordered]@{ x = 1 })
        $json = ConvertTo-AduanaJson -Valor ([ordered]@{ l = $lista })
        ($json | ConvertFrom-Json).l.Count | Should -Be 1
        $json | Should -Match '"l": \['
    }

    It 'escapa comillas, barras, controles y los caracteres de engaño, y deja el resto en crudo' {
        $texto = 'a"b\c' + "`n" + [char]0x01 + $RLO + $PuntoFalso + $EspacioCero + 'ñé'
        $json = ConvertTo-AduanaJson -Valor $texto -Reglas $Reglas
        $json | Should -BeExactly ('"a\"b\\c\n\u0001\u202e\u2024\u200b' + 'ñé' + '"')
        ($json | ConvertFrom-Json) | Should -BeExactly $texto
    }
}

Describe 'Nombres seguros en el informe de texto' {
    It 'sustituye los caracteres de engaño y de control por su código' {
        $nombre = "foto$($RLO)gpj.exe" + [char]0x7f
        Format-AduanaNombreSeguro -Texto $nombre -Reglas $Reglas | Should -BeExactly ('foto' + [char]0x27E8 + 'U+202E' + [char]0x27E9 + 'gpj.exe' + [char]0x27E8 + 'U+007F' + [char]0x27E9)
    }

    It 'deja intactas las tildes' {
        Format-AduanaNombreSeguro -Texto 'Canción.mp3' -Reglas $Reglas | Should -BeExactly 'Canción.mp3'
    }
}

Describe 'Argumentos' {
    It 'sin argumentos muestra la ayuda' {
        (ConvertFrom-AduanaArgumentos -Argumentos @()).Orden | Should -Be 'ayuda'
    }

    It 'traduce los alias en inglés' -TestCases @(
        @{ Entrada = @('help'); Orden = 'ayuda' }
        @{ Entrada = @('--version'); Orden = 'version' }
        @{ Entrada = @('prepare-host'); Orden = 'preparar-equipo' }
        @{ Entrada = @('restore-host'); Orden = 'restaurar-equipo' }
        @{ Entrada = @('mount'); Orden = 'montar' }
        @{ Entrada = @('inspect', 'E:\'); Orden = 'inspeccionar' }
        @{ Entrada = @('copy', 'a', 'b'); Orden = 'copiar' }
        @{ Entrada = @('verify', 'a'); Orden = 'verificar' }
        @{ Entrada = @('sentinel'); Orden = 'centinela' }
        @{ Entrada = @('out', 'prepare', '3'); Orden = 'salida-preparar' }
        @{ Entrada = @('out', 'clean', 'E:\'); Orden = 'salida-limpiar' }
        @{ Entrada = @('out', 'check-capacity', 'E:\'); Orden = 'salida-comprobar-capacidad' }
        @{ Entrada = @('out', 'sign', 'E:\', '--clave', 'k'); Orden = 'salida-firmar' }
        @{ Entrada = @('out', 'encrypt', 'c'); Orden = 'salida-cifrar' }
        @{ Entrada = @('salida', 'comprobar-capacidad', 'E:\'); Orden = 'salida-comprobar-capacidad' }
    ) {
        param($Entrada, $Orden)
        (ConvertFrom-AduanaArgumentos -Argumentos $Entrada).Orden | Should -Be $Orden
    }

    It 'separa opciones booleanas, opciones con valor y posicionales' {
        $p = ConvertFrom-AduanaArgumentos -Argumentos @('verificar', 'E:\', '--json', '--confiar', 'Ana', '--firmantes', 'f.txt')
        $p.Posicionales | Should -Be @('E:\')
        $p.Opciones['json'] | Should -BeTrue
        $p.Opciones['confiar'] | Should -Be 'Ana'
        $p.Opciones['firmantes'] | Should -Be 'f.txt'
    }

    It 'rechaza con código 3 <Caso>' -TestCases @(
        @{ Caso = 'una orden desconocida'; Entrada = @('volar') }
        @{ Caso = 'una opción que la orden no admite'; Entrada = @('inspeccionar', 'E:\', '--rapido') }
        @{ Caso = 'una opción sin su valor'; Entrada = @('verificar', 'E:\', '--confiar') }
        @{ Caso = 'argumentos de más'; Entrada = @('inspeccionar', 'a', 'b') }
        @{ Caso = 'argumentos de menos'; Entrada = @('copiar', 'a') }
        @{ Caso = 'una orden de salida desconocida'; Entrada = @('salida', 'volar') }
        @{ Caso = 'salida sin orden'; Entrada = @('salida') }
    ) {
        param($Entrada)
        $codigo = $null
        try { $null = ConvertFrom-AduanaArgumentos -Argumentos $Entrada } catch { $codigo = $_.Exception.Data['AduanaCodigo'] }
        $codigo | Should -Be 3
    }
}

Describe 'Argumentos para procesos externos' {
    It 'entrecomilla según las reglas de Windows' -TestCases @(
        @{ Entrada = 'simple'; Salida = 'simple' }
        @{ Entrada = ''; Salida = '""' }
        @{ Entrada = 'con espacio'; Salida = '"con espacio"' }
        @{ Entrada = 'E:\'; Salida = 'E:\' }
        @{ Entrada = 'C:\Mis cosas\'; Salida = '"C:\Mis cosas\\"' }
        @{ Entrada = 'di "hola"'; Salida = '"di \"hola\""' }
    ) {
        param($Entrada, $Salida)
        ConvertTo-AduanaArgumento -Argumento $Entrada | Should -BeExactly $Salida
    }
}

Describe 'Rutas' {
    It 'calcula rutas relativas con barras normales' {
        Get-AduanaRutaRelativa -Raiz 'E:\' -Ruta 'E:\a\b.txt' | Should -Be 'a/b.txt'
        Get-AduanaRutaRelativa -Raiz '/tmp/x' -Ruta '/tmp/x/a/b' | Should -Be 'a/b'
        Get-AduanaRutaRelativa -Raiz '/tmp/x' -Ruta '/tmp/x' | Should -Be '.'
    }

    It 'detecta un destino dentro del origen' {
        $origen = Join-Path $TestDrive 'o'
        Test-AduanaRutaDentro -Hija (Join-Path $origen 'd') -Padre $origen | Should -BeTrue
        Test-AduanaRutaDentro -Hija $origen -Padre $origen | Should -BeTrue
        Test-AduanaRutaDentro -Hija (Join-Path $TestDrive 'otro') -Padre $origen | Should -BeFalse
        Test-AduanaRutaDentro -Hija (Join-Path $TestDrive 'o2') -Padre $origen | Should -BeFalse
    }

    It 'formatea tamaños con coma decimal' {
        Format-AduanaTamano -Bytes 1500000 | Should -Be '1,5 MB'
        Format-AduanaTamano -Bytes 999 | Should -Be '999 B'
    }
}

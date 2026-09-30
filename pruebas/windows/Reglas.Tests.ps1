BeforeAll {
    . (Join-Path $PSScriptRoot 'Cargar.ps1')
    $pendrive = Join-Path $TestDrive 'pendrive'
    New-FixturePendrive -Raiz $pendrive
    $recorrido = Invoke-AduanaRecorrido -Raiz $pendrive -Reglas $Reglas
    $pares = Get-ParesHallazgos $recorrido.Hallazgos
}

Describe 'Inspección del pendrive de pruebas' {
    It 'detecta <Regla> en <Ruta>' -TestCases @(
        @{ Ruta = 'factura.pdf.exe'; Regla = 'doble-extension' }
        @{ Ruta = 'factura.pdf     .exe'; Regla = 'extension-camuflada' }
        @{ Ruta = 'foto{RLO}gpj.exe'; Regla = 'caracter-bidi' }
        @{ Ruta = 'foto{RLO}gpj.exe'; Regla = 'extension-peligrosa' }
        @{ Ruta = 'informe{PUNTO}pdf'; Regla = 'punto-falso' }
        @{ Ruta = 'fac{CERO}tura.txt'; Regla = 'caracter-invisible' }
        @{ Ruta = 'autorun.inf'; Regla = 'autorun' }
        @{ Ruta = 'sub/autorun.inf'; Regla = 'autorun' }
        @{ Ruta = 'desktop.ini'; Regla = 'desktop-ini' }
        @{ Ruta = 'carta.docm'; Regla = 'extension-peligrosa' }
        @{ Ruta = 'viejo.doc'; Regla = 'macros' }
        @{ Ruta = 'trampa.docx'; Regla = 'macros' }
        @{ Ruta = 'foto.jpg'; Regla = 'contenido-ejecutable' }
        @{ Ruta = 'instalar'; Regla = 'script-sin-extension' }
        @{ Ruta = '.DS_Store'; Regla = 'artefacto-sistema' }
        @{ Ruta = '._x'; Regla = 'artefacto-sistema' }
        @{ Ruta = '._trampa.exe'; Regla = 'extension-peligrosa' }
        @{ Ruta = '.oculto.txt'; Regla = 'oculto' }
        @{ Ruta = 'Programa.app'; Regla = 'extension-peligrosa' }
        @{ Ruta = 'pagina.html'; Regla = 'extension-sospechosa' }
        @{ Ruta = 'enlace'; Regla = 'enlace-simbolico' }
    ) {
        param($Ruta, $Regla)
        $real = $Ruta.Replace('{RLO}', $RLO).Replace('{PUNTO}', $PuntoFalso).Replace('{CERO}', $EspacioCero)
        $pares | Should -Contain "$real|$Regla"
    }

    It 'da el nivel esperado a cada regla' {
        $niveles = @{}
        foreach ($h in $recorrido.Hallazgos) { $niveles["$($h.ruta)|$($h.regla)"] = $h.nivel }
        $niveles['autorun.inf|autorun'] | Should -Be 'peligroso'
        $niveles['sub/autorun.inf|autorun'] | Should -Be 'sospechoso'
        $niveles['desktop.ini|desktop-ini'] | Should -Be 'sospechoso'
        $niveles["fac$($EspacioCero)tura.txt|caracter-invisible"] | Should -Be 'sospechoso'
        $niveles['enlace|enlace-simbolico'] | Should -Be 'sospechoso'
        $niveles['.oculto.txt|oculto'] | Should -Be 'informativo'
        $niveles['foto.jpg|contenido-ejecutable'] | Should -Be 'peligroso'
    }

    It 'no reporta nada del fichero limpio de control ni de una foto normal' {
        @($pares | Where-Object { $_ -like 'notas.txt|*' }) | Should -BeNullOrEmpty
        @($pares | Where-Object { $_ -like 'Fotos/*' }) | Should -BeNullOrEmpty
    }

    It 'no reporta dos veces la misma extensión con reglas que se sustituyen' {
        $pares | Should -Not -Contain 'factura.pdf.exe|extension-peligrosa'
        $pares | Should -Not -Contain 'factura.pdf     .exe|extension-peligrosa'
        $pares | Should -Not -Contain 'factura.pdf.exe|contenido-ejecutable'
        $pares | Should -Not -Contain 'carta.docm|macros'
    }

    It 'no entra en los paquetes de macOS ni en los artefactos' {
        @($pares | Where-Object { $_ -like 'Programa.app/*' }) | Should -BeNullOrEmpty
        $pares | Should -Not -Contain '.DS_Store|oculto'
    }

    It 'no sigue los enlaces' {
        @($recorrido.Entradas | Where-Object { $_.Rel -like 'enlace/*' }) | Should -BeNullOrEmpty
    }

    It 'cuenta ficheros y carpetas' {
        $recorrido.Carpetas | Should -Be 3
        $recorrido.Ficheros | Should -BeGreaterThan 15
    }
}

Describe 'Reglas de nombre sueltas' {
    It 'detecta una carpeta suplantada por un acceso directo con su nombre' {
        $ocultos = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        [void]$ocultos.Add('Fotos')
        $h = Get-AduanaHallazgosNombre -Nombre 'fotos.lnk' -Reglas $Reglas -DirectoriosOcultos $ocultos
        @($h | ForEach-Object { $_.Regla }) | Should -Be @('carpeta-suplantada')
        $h[0].Nivel | Should -Be 'peligroso'
    }

    It 'un acceso directo normal es solo extensión peligrosa' {
        $ocultos = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        $h = Get-AduanaHallazgosNombre -Nombre 'Fotos.lnk' -Reglas $Reglas -DirectoriosOcultos $ocultos
        @($h | ForEach-Object { $_.Regla }) | Should -Be @('extension-peligrosa')
    }

    It 'una doble extensión sin documento delante es una extensión normal' {
        $h = Get-AduanaHallazgosNombre -Nombre 'setup.v2.exe' -Reglas $Reglas
        @($h | ForEach-Object { $_.Regla }) | Should -Be @('extension-peligrosa')
    }

    It 'la doble extensión solo cuenta con extensiones peligrosas' {
        $h = Get-AduanaHallazgosNombre -Nombre 'foto.jpg.html' -Reglas $Reglas
        @($h | ForEach-Object { $_.Regla }) | Should -Be @('extension-sospechosa')
    }

    It 'calcula extensiones' {
        Get-AduanaExtension -Nombre '.bashrc' | Should -Be ''
        Get-AduanaExtension -Nombre 'a.' | Should -Be ''
        Get-AduanaExtension -Nombre 'A.EXE' | Should -Be 'exe'
        Get-AduanaPenultimaExtension -Nombre 'factura.PDF.exe' | Should -Be 'pdf'
        Get-AduanaPenultimaExtension -Nombre 'factura.pdf     .exe' | Should -Be 'pdf'
    }
}

Describe 'Límites del recorrido' {
    It 'se detiene al superar la profundidad máxima' {
        $raiz = Join-Path $TestDrive 'hondo'
        $ruta = $raiz
        foreach ($i in 1..4) { $ruta = Join-Path $ruta "n$i" }
        [void][IO.Directory]::CreateDirectory($ruta)
        $r = Invoke-AduanaRecorrido -Raiz $raiz -Reglas $Reglas -ProfundidadMaxima 2
        Get-ParesHallazgos $r.Hallazgos | Should -Contain 'n1/n2/n3|limite-alcanzado'
    }

    It 'se detiene al superar el número de entradas' {
        $raiz = Join-Path $TestDrive 'ancho'
        foreach ($i in 1..5) { Write-FixtureTexto (Join-Path $raiz "f$i.txt") 'x' }
        $r = Invoke-AduanaRecorrido -Raiz $raiz -Reglas $Reglas -EntradasMaximas 3
        Get-ParesHallazgos $r.Hallazgos | Should -Contain '.|limite-alcanzado'
    }

    It 'falla con código 3 si la ruta no existe' {
        $codigo = $null
        try { $null = Invoke-AduanaRecorrido -Raiz (Join-Path $TestDrive 'no-existe') -Reglas $Reglas } catch { $codigo = $_.Exception.Data['AduanaCodigo'] }
        $codigo | Should -Be 3
    }
}

Describe 'Orden y veredicto' {
    It 'ordena por nivel y después por ruta ordinal' {
        $lista = @(
            (New-AduanaHallazgo 'informativo' 'oculto' 'a' ''),
            (New-AduanaHallazgo 'peligroso' 'x' 'b' ''),
            (New-AduanaHallazgo 'sospechoso' 'x' 'a' ''),
            (New-AduanaHallazgo 'peligroso' 'x' 'B' '')
        )
        $ordenados = Get-AduanaHallazgosOrdenados -Hallazgos $lista
        @($ordenados | ForEach-Object { "$($_.nivel)|$($_.ruta)" }) | Should -Be @('peligroso|B', 'peligroso|b', 'sospechoso|a', 'informativo|a')
    }

    It 'da el veredicto según el peor nivel' {
        (Get-AduanaVeredicto -Resumen @{ peligroso = 0; sospechoso = 0 }).Codigo | Should -Be 0
        (Get-AduanaVeredicto -Resumen @{ peligroso = 0; sospechoso = 2 }).Codigo | Should -Be 1
        (Get-AduanaVeredicto -Resumen @{ peligroso = 1; sospechoso = 2 }).Veredicto | Should -Be 'peligroso'
    }
}

Describe 'Dispositivo, Defender y VirusTotal' {
    It 'clasifica las interfaces del dispositivo' {
        $interfaces = @(@{ Clase = 'Keyboard'; Nombre = 'Teclado HID' }, @{ Clase = 'Net'; Nombre = 'RNDIS' }, @{ Clase = 'CDROM'; Nombre = 'CD virtual' })
        $h = Get-AduanaHallazgosDispositivo -Interfaces $interfaces -ParticionesOcultas @('partición 2 de 8 MB, tipo IFS')
        Get-ParesHallazgos $h | Should -Be @('.|dispositivo-hid', '.|dispositivo-red', '.|unidad-cd-virtual', '.|particion-oculta')
        $h[0].nivel | Should -Be 'peligroso'
    }

    It 'lee las detecciones de MpCmdRun' {
        $salida = @'
Scan starting...
Scan finished.
Scanning E:\ found 2 threats.

<===========================LIST OF DETECTED THREATS==========================>
----------------------------- Threat information ------------------------------
Threat                  : Virus:DOS/EICAR_Test_File
Resources               : 1 total
    file                : E:\eicar.com
----------------------------- Threat information ------------------------------
Threat                  : Trojan:Win32/Falso
Resources               : 1 total
    file                : E:\sub\falso.exe
-------------------------------------------------------------------------------
'@
        $r = ConvertFrom-AduanaSalidaDefender -Salida $salida -Codigo 2
        $r.Estado | Should -Be 'detecciones'
        $r.Detecciones.Count | Should -Be 2
        $r.Detecciones[0].Amenaza | Should -Be 'Virus:DOS/EICAR_Test_File'
        $r.Detecciones[1].Fichero | Should -Be 'E:\sub\falso.exe'
    }

    It 'distingue limpio de error en MpCmdRun' {
        (ConvertFrom-AduanaSalidaDefender -Salida 'Scan finished.' -Codigo 0).Estado | Should -Be 'limpio'
        (ConvertFrom-AduanaSalidaDefender -Salida 'Failed' -Codigo 1).Estado | Should -Be 'error'
    }

    It 'gradúa VirusTotal' {
        Get-AduanaNivelVirusTotal -Maliciosos 0 | Should -BeNullOrEmpty
        Get-AduanaNivelVirusTotal -Maliciosos 2 | Should -Be 'sospechoso'
        Get-AduanaNivelVirusTotal -Maliciosos 3 | Should -Be 'peligroso'
    }
}

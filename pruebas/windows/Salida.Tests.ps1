BeforeAll {
    . (Join-Path $PSScriptRoot 'Cargar.ps1')

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

    function New-DocxConMetadatos {
        param([string]$Ruta)
        New-FixtureZip $Ruta @{
            '[Content_Types].xml' = '<Types/>'
            'word/document.xml'   = '<w:document/>'
            'docProps/core.xml'   = '<cp:coreProperties xmlns:dc="d" xmlns:cp="c"><dc:title>Informe</dc:title><dc:creator>Ana López</dc:creator><cp:lastModifiedBy>Luis</cp:lastModifiedBy></cp:coreProperties>'
            'docProps/app.xml'    = '<Properties><Company>ACME</Company><Manager>Jefa</Manager><Pages>1</Pages></Properties>'
        }
    }
}

Describe 'Metadatos' {
    It 'lee y vacía los metadatos de Office sin tocar el resto' {
        $xml = '<p><dc:creator>Ana</dc:creator><dc:title>T</dc:title><Company attr="1">ACME</Company></p>'
        $m = Get-AduanaMetadatosXml -Xml $xml
        @($m) | Should -Be @('autor «Ana»', 'empresa «ACME»')
        Remove-AduanaMetadatosXml -Xml $xml | Should -BeExactly '<p><dc:creator></dc:creator><dc:title>T</dc:title><Company attr="1"></Company></p>'
    }

    It 'limpia un docx de verdad' {
        $docx = Join-Path $TestDrive 'informe.docx'
        New-DocxConMetadatos -Ruta $docx
        (Get-AduanaMetadatosOoxml -Ruta $docx).Count | Should -Be 4
        Clear-AduanaMetadatosOoxml -Ruta $docx
        (Get-AduanaMetadatosOoxml -Ruta $docx).Count | Should -Be 0
        $zip = [IO.Compression.ZipFile]::OpenRead($docx)
        try {
            $core = Read-AduanaEntradaZip -Zip $zip -Nombre 'docProps/core.xml'
            $core | Should -Match '<dc:title>Informe</dc:title>'
            (Read-AduanaEntradaZip -Zip $zip -Nombre 'word/document.xml') | Should -Be '<w:document/>'
        }
        finally {
            $zip.Dispose()
        }
    }

    It 'detecta GPS en un JPEG y no en uno sin él' {
        Test-AduanaGpsJpeg -Bytes (Get-BytesJpegConGps) | Should -BeTrue
        Test-AduanaGpsJpeg -Bytes (Get-BytesJpegConGps -SinGps) | Should -BeFalse
        Test-AduanaGpsJpeg -Bytes ([byte[]]@(0xff, 0xd8, 0xff, 0xd9)) | Should -BeFalse
        Test-AduanaGpsJpeg -Bytes ([byte[]]@(1, 2, 3)) | Should -BeFalse
    }

    It 'detecta el autor de un PDF' {
        $m = Get-AduanaMetadatosPdf -Texto '%PDF-1.4 << /Author (Ana) /Producer (x) >>'
        @($m) | Should -Be @('autor «Ana»')
        (Get-AduanaMetadatosPdf -Texto '%PDF-1.4 << /Producer (x) >>').Count | Should -Be 0
    }
}

Describe 'salida limpiar' {
    BeforeEach {
        $vol = Join-Path $TestDrive ("limpiar-" + [Guid]::NewGuid().ToString('N'))
        Write-FixtureTexto (Join-Path $vol '.DS_Store') 'x'
        Write-FixtureTexto (Join-Path $vol '._foto.jpg') 'x'
        Write-FixtureTexto (Join-Path (Join-Path $vol 'sub') 'Thumbs.db') 'x'
        Write-FixtureTexto (Join-Path (Join-Path $vol '.Spotlight-V100') 'Store') 'x'
        Write-FixtureTexto (Join-Path $vol 'desktop.ini') "[.ShellClassInfo]`r`nIconResource=x`r`n"
        New-DocxConMetadatos -Ruta (Join-Path $vol 'informe.docx')
        Write-FixtureBytes (Join-Path $vol 'foto.jpg') (Get-BytesJpegConGps)
        Write-FixtureTexto (Join-Path $vol 'doc.pdf') '%PDF-1.4 << /Author (Ana) >>'
        Write-FixtureTexto (Join-Path $vol 'notas.txt') 'hola'
        Mock Find-AduanaExiftool { $null }
    }

    It 'borra la basura del sistema, limpia Office y avisa de lo que necesita exiftool' {
        $r = Invoke-Capturado -Argumentos @('salida', 'limpiar', $vol)
        $r.Codigo | Should -Be 0
        foreach ($n in @('.DS_Store', '._foto.jpg', '.Spotlight-V100', 'desktop.ini')) {
            Test-Path (Join-Path $vol $n) | Should -BeFalse
        }
        Test-Path (Join-Path (Join-Path $vol 'sub') 'Thumbs.db') | Should -BeFalse
        Test-Path (Join-Path $vol 'notas.txt') | Should -BeTrue
        (Get-AduanaMetadatosOoxml -Ruta (Join-Path $vol 'informe.docx')).Count | Should -Be 0
        $r.Salida | Should -Match 'ubicación GPS'
        $r.Salida | Should -Match 'autor «Ana»'
        $r.Salida | Should -Match 'exiftool'
    }

    It 'con --solo-informe no toca nada' {
        $r = Invoke-Capturado -Argumentos @('out', 'clean', $vol, '--solo-informe')
        $r.Codigo | Should -Be 0
        Test-Path (Join-Path $vol '.DS_Store') | Should -BeTrue
        (Get-AduanaMetadatosOoxml -Ruta (Join-Path $vol 'informe.docx')).Count | Should -Be 4
    }

    It 'usa exiftool con fotos y PDF si está' {
        Mock Find-AduanaExiftool { 'exiftool' }
        Mock Invoke-AduanaExiftool { 0 }
        $null = Invoke-Capturado -Argumentos @('salida', 'limpiar', $vol)
        Should -Invoke Invoke-AduanaExiftool -Times 2 -Exactly
    }

    It 'no borra un desktop.ini con CLSID y avisa' {
        Write-FixtureTexto (Join-Path $vol 'desktop.ini') "[.ShellClassInfo]`r`nCLSID={645FF040-5081-101B-9F08-00AA002F954E}`r`n"
        $r = Invoke-Capturado -Argumentos @('salida', 'limpiar', $vol)
        Test-Path (Join-Path $vol 'desktop.ini') | Should -BeTrue
        $r.Salida | Should -Match 'componente del sistema'
    }
}

Describe 'Comprobación de capacidad' {
    It 'genera bloques distintos y deterministas' {
        $g1 = New-AduanaGeneradorCapacidad -Semilla 's'
        $g2 = New-AduanaGeneradorCapacidad -Semilla 's'
        $a = Get-AduanaBloqueCapacidad -Generador $g1 -Fichero 1 -Bloque 0
        $b = Get-AduanaBloqueCapacidad -Generador $g1 -Fichero 1 -Bloque 1
        $c = Get-AduanaBloqueCapacidad -Generador $g2 -Fichero 1 -Bloque 0
        $a.Length | Should -Be 1048576
        [Convert]::ToBase64String($a) | Should -Be ([Convert]::ToBase64String($c))
        [Convert]::ToBase64String($a) | Should -Not -Be ([Convert]::ToBase64String($b))
    }

    It 'detecta un bloque que no se lee igual que se escribió' {
        $raiz = Join-Path $TestDrive 'capacidad'
        [void][IO.Directory]::CreateDirectory($raiz)
        $e = Write-AduanaDatosCapacidad -Raiz $raiz -Total (3 * 1048576) -Semilla 'x' -BloquesPorFichero 2
        $e.Ficheros.Count | Should -Be 2
        $e.Escritos | Should -Be (3 * 1048576)
        (Test-AduanaDatosCapacidad -Ficheros $e.Ficheros -Huellas $e.Huellas -BloquesPorFichero 2).Verificados | Should -Be (3 * 1048576)
        # Simula un pendrive falso: el tercer bloque devuelve lo mismo que el primero.
        $primero = [IO.File]::ReadAllBytes($e.Ficheros[0])[0..1048575]
        [IO.File]::WriteAllBytes($e.Ficheros[1], [byte[]]$primero)
        $l = Test-AduanaDatosCapacidad -Ficheros $e.Ficheros -Huellas $e.Huellas -BloquesPorFichero 2
        $l.Verificados | Should -Be (2 * 1048576)
        $l.PrimerFallo | Should -Be (2 * 1048576)
    }

    It 'la orden escribe, comprueba y borra sus ficheros' {
        $raiz = Join-Path $TestDrive 'capacidad-orden'
        [void][IO.Directory]::CreateDirectory($raiz)
        Mock Get-AduanaEspacioLibre { [long]10 * 1048576 }
        Mock Clear-AduanaCacheDisco { }
        $r = Invoke-Capturado -Argumentos @('salida', 'comprobar-capacidad', $raiz, '--limite', '3')
        $r.Codigo | Should -Be 0
        $r.Salida | Should -Match 'Todo lo escrito'
        @(Get-ChildItem -LiteralPath $raiz).Count | Should -Be 0
        Should -Invoke Clear-AduanaCacheDisco -Times 1 -Exactly
    }

    It 'devuelve 2 si lo leído no coincide' {
        $raiz = Join-Path $TestDrive 'capacidad-falsa'
        [void][IO.Directory]::CreateDirectory($raiz)
        Mock Get-AduanaEspacioLibre { [long]10 * 1048576 }
        Mock Clear-AduanaCacheDisco { [IO.File]::WriteAllBytes((Join-Path $Ruta 'ADUANA-CAPACIDAD-0001.bin'), (New-Object byte[] 1048576)) }
        (Invoke-Capturado -Argumentos @('out', 'check-capacity', $raiz, '--limite', '2')).Codigo | Should -Be 2
        @(Get-ChildItem -LiteralPath $raiz).Count | Should -Be 0
    }

    It 'rechaza un límite que no es un número' {
        (Invoke-Capturado -Argumentos @('salida', 'comprobar-capacidad', $TestDrive, '--limite', 'mucho')).Codigo | Should -Be 3
    }
}

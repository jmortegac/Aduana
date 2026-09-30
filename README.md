# Aduana

**Kit de seguridad para pendrives en Windows y macOS.** Revisa los pendrives que te prestan antes
de fiarte de ellos y prepara los tuyos antes de prestarlos.

[English](README.en.md)

> Aduana reduce riesgos, no los elimina. Lee [qué no hace](#qué-no-hace) antes de confiar en él.

## Por qué

Un pendrive ajeno ya no se ejecuta solo al conectarlo, porque Windows dejó de hacer autorun en 2011
y macOS nunca lo hizo. El peligro de hoy es otro:

- **Ficheros disfrazados.** Un acceso directo con icono de carpeta que sustituye a la carpeta de
  verdad, que queda oculta, un `factura.pdf.exe`, o un nombre con caracteres invisibles que dan la
  vuelta a la extensión.
- **Lo que viene de un USB no lleva marca de origen.** Un documento descargado de internet se abre
  en Vista protegida y una aplicación descargada pasa por Gatekeeper, pero la misma copia sacada de
  un pendrive **no recibe esa marca** y el sistema se fía de ella. Aduana copia los ficheros
  poniéndoles la marca, para que las defensas del sistema vuelvan a funcionar.
- **El pendrive que en realidad es un teclado.** Un dispositivo BadUSB se anuncia como teclado y
  escribe comandos a toda velocidad. Revisar ficheros no sirve de nada contra eso, así que Aduana
  comprueba qué más expone el dispositivo y puede bloquear la sesión si aparece un teclado nuevo.

Y al prestar un pendrive propio el riesgo va al revés: ficheros borrados que se pueden recuperar,
fotos con la ubicación GPS, documentos con tu nombre y el de tu empresa, y la basura que deja cada
sistema.

## Instalación

No hay nada que instalar. Descarga la última versión desde
[Releases](https://github.com/jmortegac/Aduana/releases), comprueba el checksum y descomprímela.

```sh
shasum -a 256 -c SHA256SUMS            # macOS
```

```powershell
Get-FileHash .\aduana-*.zip -Algorithm SHA256   # Windows, compáralo con SHA256SUMS
```

Cada versión lleva además una atestación de procedencia de GitHub, que puedes verificar con
`gh attestation verify aduana-X.Y.Z.zip --repo jmortegac/Aduana`.

**macOS** usa solo lo que trae el sistema (zsh, `diskutil`, `xattr`, `ssh-keygen`).

```sh
./macos/aduana ayuda
```

**Windows** usa el PowerShell 5.1 que viene de serie. Los scripts no están firmados, así que Windows
no los ejecuta con la directiva por defecto. En lugar de relajarla para todo el equipo, ábrelos solo
para esa sesión:

```powershell
powershell -ExecutionPolicy Bypass -File .\windows\Aduana.ps1 ayuda
```

Lee el código antes de ejecutarlo. Es corto a propósito.

## Uso

### Entrada: me prestan un pendrive

```sh
aduana preparar-equipo              # una sola vez, endurece el equipo (restaurar-equipo lo deshace)
aduana centinela --durante 60       # opcional, vigila si aparece un teclado nuevo mientras lo conectas
aduana montar <disco>               # lo monta en solo lectura
aduana inspeccionar <volumen>       # informe de lo que hay y de lo que parece
aduana copiar <volumen> <destino>   # copia lo que no es peligroso, con marca de origen
aduana verificar <volumen>          # si lo preparó otra persona con Aduana, comprueba su firma
```

`inspeccionar` no escribe nada en el pendrive. Revisa:

- extensiones que ejecutan código, según [reglas/reglas.json](reglas/reglas.json);
- dobles extensiones, extensiones escondidas tras espacios y caracteres que dan la vuelta al nombre
  o que imitan un punto;
- carpetas ocultas suplantadas por un acceso directo con el mismo nombre;
- `autorun.inf`, `desktop.ini` y enlaces simbólicos;
- documentos con macros, también cuando la extensión lo disimula;
- programas con extensión de documento, y scripts sin extensión, que macOS ejecuta con doble clic;
- el dispositivo en sí, es decir, si además de almacenamiento expone un teclado, una tarjeta de red
  o un CD virtual, y si tiene particiones ocultas;
- el antivirus del sistema (Microsoft Defender en Windows, ClamAV en macOS si está instalado);
- opcionalmente VirusTotal, **solo por hash**, sin subir nada. Define `VT_API_KEY` y añade
  `--virustotal`.

### Salida: preparo un pendrive para prestarlo

```sh
aduana salida preparar <disco>             # borra y formatea en exFAT, legible en Windows y macOS
aduana salida limpiar <volumen>            # quita la basura del sistema y los metadatos personales
aduana salida comprobar-capacidad <volumen> # detecta pendrives que mienten sobre su tamaño
aduana salida firmar <volumen> --clave ~/.ssh/id_ed25519
aduana salida cifrar <carpeta>             # zip cifrado con AES-256, si tienes 7-Zip
```

`firmar` escribe un manifiesto con el SHA-256 de cada fichero y lo firma con tu clave SSH, así que no
hace falta instalar nada. Quien lo recibe comprueba con `aduana verificar` que nadie ha añadido,
quitado ni cambiado nada desde que lo firmaste, siempre que confirme contigo la huella de la clave
por otro canal.

### Solo Windows

```powershell
aduana sandbox E:\    # abre el pendrive en Windows Sandbox, en solo lectura y sin red
```

### Salida y códigos de retorno

Todas las órdenes de revisión aceptan `--json`. Los códigos de retorno son:

| Código | Significado |
| --- | --- |
| 0 | Sin hallazgos peligrosos ni sospechosos, o la orden terminó bien |
| 1 | Hay hallazgos sospechosos y ninguno peligroso |
| 2 | Hay hallazgos peligrosos, o la verificación de la firma falló |
| 3 | Error de uso, del entorno, o cancelado |

Las órdenes tienen alias en inglés (`inspect`, `copy`, `verify`, `out prepare`...). `aduana ayuda`
los lista todos.

## Qué no hace

- **No detecta un BadUSB por sus ficheros**, porque no los necesita. Lo que hace es ver si el
  dispositivo se anuncia también como teclado y bloquear la sesión si aparece uno nuevo mientras
  vigila. Hay una ventana de carrera, y un dispositivo que espera antes de anunciarse la esquiva.
- **No lee el firmware del pendrive.** Un controlador USB modificado puede mentir sobre lo que es.
- **No protege del hardware destructivo**, como USB Killer, que descarga alta tensión en el puerto.
- **No protege de fallos del propio sistema** en el controlador USB o en el sistema de ficheros, que
  se disparan al conectar, antes de que Aduana haga nada.
- **No sustituye a un antivirus.** Usa el del sistema y busca patrones de engaño, nada más.
- **En macOS no impide el automontaje.** Hay una ventana entre que el sistema monta el pendrive y
  Aduana lo remonta en solo lectura.
- **El borrado de `salida preparar` no es forense.** La memoria flash reparte las escrituras y deja
  copias que el sistema no ve. Si el contenido era delicado, lo seguro es haberlo cifrado desde el
  principio.

Si el pendrive te preocupa de verdad, no lo conectes a tu equipo. Usa uno sacrificable, una máquina
virtual o una estación dedicada como [CIRCLean](https://www.circl.lu/projects/CIRCLean/).

## Pruebas

```sh
pruebas/macos/ejecutar.zsh        # en un Mac, con imágenes de disco exFAT que hacen de pendrive
pruebas/ejecutar-docker.sh        # la parte de Windows, en un contenedor Linux con PowerShell 7
pruebas/interoperabilidad.zsh     # lo firmado en un sistema se verifica en el otro
```

Los ficheros trampa se generan durante la prueba, así que el repositorio no contiene nada
malicioso. El contenedor analiza la compatibilidad con PowerShell 5.1 y prueba la lógica, pero lo
que toca Windows de verdad (registro, discos, Defender, Sandbox) solo se prueba en el CI, sobre
Windows real.

## Precedentes y créditos

Aduana se apoya en ideas de proyectos que merecen la pena: CIRCLean (CIRCL),
[Dangerzone](https://dangerzone.rocks) (Freedom of the Press Foundation), DuckHunt, BeamGun,
UKIP (Google) y USBGuard.

## Seguridad

Para avisar de una vulnerabilidad lee [SECURITY.md](SECURITY.md). No abras una issue pública.

## Licencia

[Apache-2.0](LICENSE).

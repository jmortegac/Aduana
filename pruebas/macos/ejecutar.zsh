#!/bin/zsh -f
# Pruebas de Aduana para macOS. Crean imágenes de disco exFAT que hacen de pendrive, generan los
# ficheros trampa en el momento (nunca hay binarios maliciosos en el repositorio) y comprueban cada
# orden. No tocan la configuración real: el estado y las preferencias van a un directorio temporal.
#
# Uso: pruebas/macos/ejecutar.zsh

emulate -R zsh
setopt no_unset pipe_fail extended_glob
export LC_ALL=en_US.UTF-8

typeset -g RAIZ=${0:A:h:h:h}
typeset -g ADUANA=$RAIZ/macos/aduana
typeset -g AYUDANTE=$RAIZ/macos/lib/ayudante.js
typeset -g TMP=$(mktemp -d -t aduana-pruebas)
export ADUANA_ESTADO=$TMP/config ADUANA_DOMINIO_DS=$TMP/ds.plist
typeset -gi OK=0 KO=0
typeset -ga DISCOS

limpiar_todo() {
  local d
  for d in $DISCOS; do hdiutil detach -force "$d" >/dev/null 2>&1; done
  rm -rf "$TMP"
}
trap limpiar_todo EXIT INT TERM

comprobar() {
  local descripcion=$1; shift
  if "$@"; then (( ++OK )); print -r -- "ok      $descripcion"
  else (( ++KO )); print -r -- "FALLO   $descripcion"; fi
}

rc_es() { [[ $1 == $2 ]] }
json_campo() { osascript -l JavaScript "$AYUDANTE" json-campo "$2" < "$1" }
contiene() { grep -qF -- "$2" "$1" }
no_contiene() { ! grep -qF -- "$2" "$1" }

# Crea un «pendrive» de prueba. Deja el disco en DISCO y el punto de montaje en VOLUMEN.
crear_pendrive() {
  local nombre=$1 tam=${2:-64m} salida
  hdiutil create -size $tam -fs ExFAT -volname "$nombre" -layout MBRSPUD "$TMP/$nombre.dmg" >/dev/null 2>&1 &&
    salida=$(hdiutil attach -nobrowse -noverify "$TMP/$nombre.dmg" 2>/dev/null) || { print -u2 "no puedo crear la imagen"; exit 1 }
  DISCO=${${(f)salida}[1]%%[[:space:]]*}
  DISCO=${DISCO#/dev/}
  VOLUMEN=${${(M)${(f)salida}:#*/Volumes/*}##*$'\t'}
  DISCOS+=("$DISCO")
}

punto_de_montaje() { osascript -l JavaScript "$AYUDANTE" plist-campos MountPoint < <(diskutil info -plist "$1") }

crear_trampas() {
  local d=$1
  mkdir -p "$d/Fotos" "$d/sub" "$d/carpeta.exe" "$d/Juego.app/Contents"
  chflags hidden "$d/Fotos"
  echo x > "$d/Fotos.lnk"
  echo x > "$d/factura.pdf.exe"
  echo x > "$d/informe$(printf '\u202e')fdp.exe"
  echo x > "$d/a$(printf '\u2024')pdf"
  echo x > "$d/carta.pdf      .scr"
  echo x > "$d/cero$(printf '\u200b')ancho.txt"
  echo x > "$d/autorun.inf"
  echo x > "$d/x.docm"
  printf '[.ShellClassInfo]\r\nCLSID={645FF040-5081-101B-9F08-00AA002F954E}\r\n' > "$d/sub/desktop.ini"
  printf 'MZ\x90\x00' > "$d/foto.jpg"
  printf '\xcf\xfa\xed\xfe' > "$d/binario"
  printf '#!/bin/sh\necho hola\n' > "$d/lanzar"
  printf '\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1' > "$d/viejo.doc"
  printf '_\0V\0B\0A\0_\0P\0R\0O\0J\0E\0C\0T\0' >> "$d/viejo.doc"
  ( cd "$TMP" && rm -rf z && mkdir -p z/word && echo x > z/word/vbaProject.bin && cd z && zip -qr "$d/trampa.docx" word )
  echo x > "$d/.DS_Store"
  printf '\x00\x05\x16\x07\x00\x02\x00\x00' > "$d/._nota.txt"
  echo x > "$d/._trampa.exe"
  echo x > "$d/Juego.app/Contents/Info.plist"
  ln -s /etc "$d/enlace"
  echo "texto normal" > "$d/nota.txt"
  echo "texto normal" > "$d/sub/limpio.txt"
}

# Un docx mínimo pero válido, con autor y empresa en los metadatos.
crear_docx() {
  local destino=$1 z=$TMP/docx
  rm -rf "$z"; mkdir -p "$z/_rels" "$z/word" "$z/docProps"
  cat > "$z/[Content_Types].xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/><Override PartName="/docProps/core.xml" ContentType="application/vnd.openxmlformats-package.core-properties+xml"/><Override PartName="/docProps/app.xml" ContentType="application/vnd.openxmlformats-officedocument.extended-properties+xml"/></Types>
EOF
  cat > "$z/_rels/.rels" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties" Target="docProps/core.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/extended-properties" Target="docProps/app.xml"/></Relationships>
EOF
  cat > "$z/word/document.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body><w:p><w:r><w:t>Contenido de prueba</w:t></w:r></w:p></w:body></w:document>
EOF
  cat > "$z/docProps/core.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<cp:coreProperties xmlns:cp="http://schemas.openxmlformats.org/package/2006/metadata/core-properties" xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:creator>Ana Pérez</dc:creator><cp:lastModifiedBy>Ana Pérez</cp:lastModifiedBy></cp:coreProperties>
EOF
  cat > "$z/docProps/app.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Properties xmlns="http://schemas.openxmlformats.org/officeDocument/2006/extended-properties"><Company>Acme Secreta</Company></Properties>
EOF
  ( cd "$z" && zip -qX -r "$destino" '[Content_Types].xml' _rels word docProps )
}

# Una foto con coordenadas GPS, hecha con ImageIO a partir de un icono del sistema.
crear_foto_gps() {
  local destino=$1
  sips -s format jpeg /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns \
    --out "$TMP/base.jpg" >/dev/null 2>&1
  osascript -l JavaScript - "$TMP/base.jpg" "$destino" <<'EOF' >/dev/null
ObjC.import('ImageIO');
function run(argv) {
  const src = $.CGImageSourceCreateWithURL($.NSURL.fileURLWithPath(argv[0]), null);
  const dst = $.CGImageDestinationCreateWithURL($.NSURL.fileURLWithPath(argv[1]), $.CGImageSourceGetType(src), 1, null);
  const gps = $.NSMutableDictionary.alloc.init;
  gps.setObjectForKey($.NSNumber.numberWithDouble(40.4168), 'Latitude');
  gps.setObjectForKey('N', 'LatitudeRef');
  gps.setObjectForKey($.NSNumber.numberWithDouble(3.7038), 'Longitude');
  gps.setObjectForKey('W', 'LongitudeRef');
  const props = $.NSMutableDictionary.alloc.init;
  props.setObjectForKey(gps, '{GPS}');
  $.CGImageDestinationAddImageFromSource(dst, src, 0, props);
  return $.CGImageDestinationFinalize(dst);
}
EOF
}

huella_volumen() {
  local v=$1
  find "$v" -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 stat -f '%N %z %m %Xf' 2>/dev/null | shasum -a 256
  find "$v" -type f -print0 2>/dev/null | LC_ALL=C sort -z | xargs -0 shasum -a 256 2>/dev/null | shasum -a 256
}

# =============================================================================================
print -r -- "== Órdenes y argumentos"

"$ADUANA" ayuda >/dev/null; comprobar "ayuda devuelve 0" rc_es $? 0
"$ADUANA" help >/dev/null; comprobar "alias help" rc_es $? 0
"$ADUANA" inventada >/dev/null 2>&1; comprobar "orden desconocida devuelve 3" rc_es $? 3
"$ADUANA" inspeccionar /tmp --inventada >/dev/null 2>&1; comprobar "opción desconocida devuelve 3" rc_es $? 3
"$ADUANA" inspeccionar >/dev/null 2>&1; comprobar "inspeccionar sin ruta devuelve 3" rc_es $? 3
"$ADUANA" sandbox /tmp >/dev/null 2>&1; comprobar "sandbox en macOS devuelve 3" rc_es $? 3
"$ADUANA" salida inventada >/dev/null 2>&1; comprobar "salida desconocida devuelve 3" rc_es $? 3
comprobar "version" contiene <("$ADUANA" version) "Aduana 0.3.0"

# El código nombra los caracteres de engaño por su código, nunca los lleva dentro: un U+202E crudo
# en un fuente da la vuelta a lo que ve quien lo revisa.
typeset -a cps=(200B 200C 200D 200E 200F 202A 202B 202C 202D 202E 2066 2067 2068 2069 2024 00AD 061C 2060 FEFF)
typeset crudos='' cp f
for cp in $cps; do crudos+=${(#):-0x$cp}; done
typeset -a con_crudos=()
for f in "$RAIZ"/macos/aduana "$RAIZ"/macos/lib/* "$RAIZ"/pruebas/macos/* "$RAIZ"/pruebas/*.zsh "$RAIZ"/reglas/reglas.json "$RAIZ"/README*.md; do
  [[ $(<"$f") == *[$crudos]* ]] && con_crudos+=("${f#$RAIZ/}")
done
comprobar "ningún carácter de engaño crudo en el fuente${con_crudos:+ (${(j:, :)con_crudos})}" test ${#con_crudos} -eq 0

# =============================================================================================
print -r -- "== Entrada, inspección"

crear_pendrive PRESTADO
crear_trampas "$VOLUMEN"
comprobar "chflags hidden funciona en exFAT" test -n "$(find "$VOLUMEN/Fotos" -maxdepth 0 -flags +hidden)"
DISCO_PRESTADO=$DISCO

"$ADUANA" montar "$DISCO_PRESTADO" >/dev/null; comprobar "montar devuelve 0" rc_es $? 0
VOL_RO=$(punto_de_montaje "${DISCO_PRESTADO}s1")
comprobar "montar lo deja en solo lectura" contiene <(mount) "$VOL_RO (exfat, local, nodev, nosuid, read-only"
"$ADUANA" montar disk0 >/dev/null 2>&1; comprobar "montar rechaza el disco interno" rc_es $? 3

ANTES=$(huella_volumen "$VOL_RO")
"$ADUANA" inspeccionar "$VOL_RO" --sin-antivirus --json > "$TMP/i.json"
comprobar "inspección peligrosa devuelve 2" rc_es $? 2
comprobar "JSON válido" rc_es "$(json_campo "$TMP/i.json" veredicto)" peligroso
comprobar "JSON dice sistema macos" rc_es "$(json_campo "$TMP/i.json" sistema)" macos

esperado() { contiene "$TMP/i.json" "\"nivel\":\"$1\",\"regla\":\"$2\",\"ruta\":\"$3\"" }
comprobar "carpeta suplantada"        esperado peligroso carpeta-suplantada Fotos.lnk
comprobar "doble extensión"           esperado peligroso doble-extension factura.pdf.exe
comprobar "RTLO, escapado en JSON"    esperado peligroso caracter-bidi 'informe\u202efdp.exe'
comprobar "punto falso"               esperado peligroso punto-falso 'a\u2024pdf'
comprobar "extensión tras espacios"   esperado peligroso extension-camuflada 'carta.pdf      .scr'
comprobar "carácter invisible"        esperado sospechoso caracter-invisible 'cero\u200bancho.txt'
comprobar "autorun en la raíz"        esperado peligroso autorun autorun.inf
comprobar "docm por extensión"        esperado peligroso extension-peligrosa x.docm
comprobar "desktop.ini con CLSID"     esperado sospechoso desktop-ini sub/desktop.ini
comprobar "jpg que es un programa"    esperado peligroso contenido-ejecutable foto.jpg
comprobar "Mach-O sin extensión"      esperado peligroso contenido-ejecutable binario
comprobar "script sin extensión"      esperado peligroso script-sin-extension lanzar
comprobar "doc OLE con macros"        esperado peligroso macros viejo.doc
comprobar "docx con vbaProject"       esperado peligroso macros trampa.docx
comprobar "aplicación de macOS"       esperado peligroso extension-peligrosa Juego.app
comprobar "enlace simbólico"          esperado sospechoso enlace-simbolico enlace
comprobar "carpeta oculta"            esperado informativo oculto Fotos
comprobar "artefacto .DS_Store"       esperado informativo artefacto-sistema .DS_Store
comprobar "artefacto AppleDouble"     esperado informativo artefacto-sistema ._nota.txt
comprobar "._ falso no es artefacto"  esperado peligroso extension-peligrosa ._trampa.exe
comprobar "no entra en el paquete"    no_contiene "$TMP/i.json" 'Juego.app/Contents'
comprobar "carpeta con .exe no cuenta" no_contiene "$TMP/i.json" '"ruta":"carpeta.exe"'
comprobar "nota.txt limpia"           no_contiene "$TMP/i.json" '"ruta":"nota.txt"'
comprobar "sub/limpio.txt limpio"     no_contiene "$TMP/i.json" '"ruta":"sub/limpio.txt"'
comprobar "autorun sin extension-sospechosa" no_contiene "$TMP/i.json" '"regla":"extension-sospechosa","ruta":"autorun.inf"'
comprobar "dispositivo detectado"     rc_es "$(json_campo "$TMP/i.json" dispositivo.bus)" "Disk Image"

"$ADUANA" inspeccionar "$VOL_RO" --sin-antivirus > "$TMP/i.txt"
comprobar "texto enseña el RTLO sin aplicarlo" contiene "$TMP/i.txt" 'informe⟨U+202E⟩fdp.exe'
comprobar "texto sin el carácter crudo" no_contiene "$TMP/i.txt" "$(printf '\u202e')"

# Una carpeta limpia devuelve 0.
mkdir -p "$TMP/limpia"; echo hola > "$TMP/limpia/a.txt"
"$ADUANA" inspeccionar "$TMP/limpia" --sin-antivirus >/dev/null; comprobar "carpeta limpia devuelve 0" rc_es $? 0
mkdir -p "$TMP/cerrada/privada"; chmod 000 "$TMP/cerrada/privada"
"$ADUANA" inspeccionar "$TMP/cerrada" --sin-antivirus --json > "$TMP/s.json"
comprobar "carpeta sin permiso da sin-acceso" contiene "$TMP/s.json" '"nivel":"informativo","regla":"sin-acceso","ruta":"privada"'
chmod 700 "$TMP/cerrada/privada"
echo x > "$TMP/limpia/b.iso"
"$ADUANA" inspeccionar "$TMP/limpia" --sin-antivirus >/dev/null; comprobar "solo sospechoso devuelve 1" rc_es $? 1

# ClamAV y VirusTotal no suelen estar instalados, así que se prueban con dobles en el PATH que
# responden como lo harían ellos.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/clamscan" <<'EOF'
#!/bin/zsh -f
print -r -- "${@[-1]}/foto.jpg: Win.Test.EICAR_HDB-1 FOUND"
exit 1
EOF
cat > "$TMP/bin/curl" <<'EOF'
#!/bin/zsh -f
# Doble de curl para la API de VirusTotal: 7 motores para foto.jpg y 404 para el resto.
local salida='' url=${@[-1]} cab=''
while (( $# )); do
  case $1 in -o) salida=$2; shift ;; -H) cab=$2; shift ;; esac
  shift
done
[[ $cab == @* ]] && grep -q 'x-apikey: clave-de-prueba' "${cab#@}" || { print -n 401; exit 0 }
if [[ $url == */$(shasum -a 256 < "$VT_FOTO" | cut -d' ' -f1) ]]; then
  print -r -- '{"data":{"attributes":{"last_analysis_stats":{"malicious":7}}}}' > "$salida"; print -n 200
else
  print -r -- '{}' > "$salida"; print -n 404
fi
EOF
chmod +x "$TMP/bin/clamscan" "$TMP/bin/curl"
PATH="$TMP/bin:$PATH" "$ADUANA" inspeccionar "$VOL_RO" --json > "$TMP/av.json"
comprobar "ClamAV, detección anotada" contiene "$TMP/av.json" '"nivel":"peligroso","regla":"antivirus","ruta":"foto.jpg","detalle":"Win.Test.EICAR_HDB-1"'
comprobar "ClamAV, estado detecciones" rc_es "$(json_campo "$TMP/av.json" antivirus.estado)" detecciones
"$ADUANA" inspeccionar "$TMP/limpia" --json > "$TMP/av.json"
comprobar "sin ClamAV, no disponible" rc_es "$(json_campo "$TMP/av.json" antivirus.estado)" no-disponible
cp "$VOL_RO/foto.jpg" "$TMP/limpia/foto.jpg"
VT_FOTO="$TMP/limpia/foto.jpg" VT_API_KEY=clave-de-prueba PATH="$TMP/bin:$PATH" \
  "$ADUANA" inspeccionar "$TMP/limpia" --sin-antivirus --virustotal --json > "$TMP/vt.json" 2>/dev/null
comprobar "VirusTotal, 7 motores es peligroso" contiene "$TMP/vt.json" '"regla":"virustotal","ruta":"foto.jpg"'
rm -f "$TMP/limpia/foto.jpg"
"$ADUANA" salida cifrar "$TMP/limpia" >/dev/null 2>&1
comprobar "cifrar sin 7-Zip devuelve 3" rc_es $? 3

# =============================================================================================
print -r -- "== Entrada, copia con marca de origen"

"$ADUANA" copiar "$VOL_RO" "$TMP/copia" --sin-antivirus --json > "$TMP/c.json"
comprobar "copiar devuelve 0" rc_es $? 0
comprobar "copia la nota" test -f "$TMP/copia/nota.txt"
comprobar "copia lo que está en subcarpetas" test -f "$TMP/copia/sub/limpio.txt"
comprobar "no copia la doble extensión" test ! -e "$TMP/copia/factura.pdf.exe"
comprobar "no copia la aplicación" test ! -e "$TMP/copia/Juego.app"
comprobar "no copia artefactos" test ! -e "$TMP/copia/.DS_Store"
comprobar "no copia el enlace" test ! -e "$TMP/copia/enlace"
comprobar "marca de cuarentena" contiene <(xattr -p com.apple.quarantine "$TMP/copia/nota.txt" 2>/dev/null) "0081;"
comprobar "la copia no es ejecutable" test ! -x "$TMP/copia/nota.txt"
comprobar "JSON de copia lista omitidos" contiene "$TMP/c.json" '"ruta":"factura.pdf.exe"'

"$ADUANA" copiar "$VOL_RO" "$TMP/copia" --sin-antivirus >/dev/null
comprobar "no sobrescribe, renombra" test -f "$TMP/copia/nota (2).txt"

"$ADUANA" copiar "$VOL_RO" "$TMP/todo" --sin-antivirus --incluir-peligrosos >/dev/null
comprobar "incluir-peligrosos copia el exe" test -f "$TMP/todo/factura.pdf.exe"
mkdir -p "$TMP/engano/carpeta$(printf '\u202e')txt.exe"
echo hola > "$TMP/engano/carpeta$(printf '\u202e')txt.exe/notas.txt"
printf 'x' > "$TMP/engano/carpeta$(printf '\u202e')txt.exe/._notas.txt"
"$ADUANA" copiar "$TMP/engano" "$TMP/engano-copia" --sin-antivirus >/dev/null
comprobar "no recrea la carpeta con nombre engañoso" test -z "$(ls -A "$TMP/engano-copia")"
comprobar "y lo marca" contiene <(xattr -p com.apple.quarantine "$TMP/todo/factura.pdf.exe" 2>/dev/null) "0081;"
comprobar "la aplicación va marcada en su raíz" contiene <(xattr -p com.apple.quarantine "$TMP/todo/Juego.app" 2>/dev/null) "0081;"

"$ADUANA" copiar "$TMP/limpia" "$TMP/limpia/dentro" --sin-antivirus >/dev/null 2>&1
comprobar "destino dentro del origen devuelve 3" rc_es $? 3

DESPUES=$(huella_volumen "$VOL_RO")
comprobar "inspeccionar y copiar no cambian el pendrive" rc_es "$ANTES" "$DESPUES"

# =============================================================================================
print -r -- "== Salida, preparar"

crear_pendrive PROPIO 96m
DISCO_PROPIO=$DISCO
"$ADUANA" salida preparar disk0 --si >/dev/null 2>&1; comprobar "preparar rechaza disk0 incluso con --si" rc_es $? 3
"$ADUANA" salida preparar "${DISCO_PROPIO}s1" --si >/dev/null 2>&1; comprobar "preparar rechaza una partición" rc_es $? 3
"$ADUANA" salida preparar "$DISCO_PROPIO" --nombre NOMBRE-DEMASIADO-LARGO --si >/dev/null 2>&1; comprobar "preparar rechaza un nombre largo" rc_es $? 3
"$ADUANA" salida preparar "$DISCO_PROPIO" </dev/null >/dev/null 2>&1; comprobar "sin confirmación no borra" rc_es $? 3
comprobar "y el volumen sigue ahí" test -d "$VOLUMEN"
"$ADUANA" salida preparar "$DISCO_PROPIO" --nombre LIMPIO --si >/dev/null; comprobar "preparar devuelve 0" rc_es $? 0
VOL_PROPIO=$(punto_de_montaje "${DISCO_PROPIO}s1")
comprobar "queda en exFAT" rc_es "$(osascript -l JavaScript "$AYUDANTE" plist-campos FilesystemType < <(diskutil info -plist "${DISCO_PROPIO}s1"))" exfat
comprobar "sin indexado de Spotlight" test -f "$VOL_PROPIO/.metadata_never_index"
comprobar "sin registro de fseventsd" test -f "$VOL_PROPIO/.fseventsd/no_log"

# =============================================================================================
print -r -- "== Salida, limpiar"

crear_docx "$VOL_PROPIO/informe.docx"
crear_foto_gps "$VOL_PROPIO/foto.jpg"
comprobar "la foto de prueba lleva GPS" contiene <(osascript -l JavaScript "$AYUDANTE" imagen-leer "$VOL_PROPIO/foto.jpg") gps
echo x > "$VOL_PROPIO/.DS_Store"; echo x > "$VOL_PROPIO/._informe.docx"; echo x > "$VOL_PROPIO/Thumbs.db"
mkdir -p "$VOL_PROPIO/deco" "$VOL_PROPIO/raro"
printf '[.ShellClassInfo]\r\nIconResource=icono.ico,0\r\n' > "$VOL_PROPIO/deco/desktop.ini"
printf '[.ShellClassInfo]\r\nCLSID={645FF040-5081-101B-9F08-00AA002F954E}\r\n' > "$VOL_PROPIO/raro/desktop.ini"
"$ADUANA" salida limpiar "$VOL_PROPIO" --solo-informe > "$TMP/l.txt"
comprobar "solo-informe ve el autor" contiene "$TMP/l.txt" "Ana Pérez"
comprobar "solo-informe ve la empresa" contiene "$TMP/l.txt" "Acme Secreta"
comprobar "solo-informe ve el GPS" contiene "$TMP/l.txt" "GPS"
comprobar "solo-informe no borra" test -f "$VOL_PROPIO/Thumbs.db"
"$ADUANA" salida limpiar "$VOL_PROPIO" >/dev/null; comprobar "limpiar devuelve 0" rc_es $? 0
comprobar "borra .DS_Store" test ! -e "$VOL_PROPIO/.DS_Store"
comprobar "borra AppleDouble" test ! -e "$VOL_PROPIO/._informe.docx"
comprobar "borra Thumbs.db" test ! -e "$VOL_PROPIO/Thumbs.db"
comprobar "borra desktop.ini decorativo" test ! -e "$VOL_PROPIO/deco/desktop.ini"
comprobar "conserva desktop.ini con CLSID" test -e "$VOL_PROPIO/raro/desktop.ini"
comprobar "conserva no_log" test -f "$VOL_PROPIO/.fseventsd/no_log"
comprobar "quita el autor del docx" no_contiene <(unzip -p "$VOL_PROPIO/informe.docx" docProps/core.xml) "Ana"
comprobar "quita la empresa del docx" no_contiene <(unzip -p "$VOL_PROPIO/informe.docx" docProps/app.xml) "Acme"
comprobar "el docx sigue abriéndose" contiene <(textutil -convert txt -stdout "$VOL_PROPIO/informe.docx" 2>/dev/null) "Contenido de prueba"
comprobar "quita el GPS de la foto" no_contiene <(osascript -l JavaScript "$AYUDANTE" imagen-leer "$VOL_PROPIO/foto.jpg") gps
comprobar "la foto sigue siendo una imagen" contiene <(sips -g pixelWidth "$VOL_PROPIO/foto.jpg" 2>/dev/null) pixelWidth

# =============================================================================================
print -r -- "== Salida, firmar y verificar"

mkdir -p "$VOL_PROPIO/docs"
echo "uno" > "$VOL_PROPIO/docs/uno.txt"
echo "dos" > "$VOL_PROPIO/$(printf 'niño.txt')"
ssh-keygen -q -t ed25519 -N '' -C prueba -f "$TMP/clave"
"$ADUANA" salida firmar "$VOL_PROPIO" >/dev/null 2>&1; comprobar "firmar sin clave devuelve 3" rc_es $? 3
cp "$TMP/clave" "$TMP/clave-abierta"; chmod 644 "$TMP/clave-abierta"
"$ADUANA" salida firmar "$VOL_PROPIO" --clave "$TMP/clave-abierta" >/dev/null 2>&1; comprobar "firma fallida devuelve 3" rc_es $? 3
comprobar "y no deja manifiesto sin firmar" test ! -e "$VOL_PROPIO/ADUANA-MANIFIESTO.txt"
"$ADUANA" salida firmar "$VOL_PROPIO" --clave "$TMP/clave" >/dev/null; comprobar "firmar devuelve 0" rc_es $? 0
comprobar "manifiesto con cabecera" contiene "$VOL_PROPIO/ADUANA-MANIFIESTO.txt" "# Aduana manifiesto v1"
comprobar "manifiesto en NFC" contiene "$VOL_PROPIO/ADUANA-MANIFIESTO.txt" "$(printf 'niño.txt')"
comprobar "manifiesto sin artefactos" no_contiene "$VOL_PROPIO/ADUANA-MANIFIESTO.txt" "no_log"
comprobar "manifiesto con el desktop.ini que lleva CLSID" contiene "$VOL_PROPIO/ADUANA-MANIFIESTO.txt" "raro/desktop.ini"

"$ADUANA" verificar "$VOL_PROPIO" --json > "$TMP/v.json"; comprobar "firmante desconocido devuelve 1" rc_es $? 1
comprobar "estado firmante-desconocido" rc_es "$(json_campo "$TMP/v.json" firma.estado)" firmante-desconocido
comprobar "veredicto intacto" rc_es "$(json_campo "$TMP/v.json" veredicto)" intacto
comprobar "huella correcta" rc_es "$(json_campo "$TMP/v.json" firma.huella)" "$(ssh-keygen -lf "$TMP/clave.pub" | cut -d' ' -f2)"
"$ADUANA" verificar "$VOL_PROPIO" --confiar "Ana Pérez" >/dev/null 2>&1; comprobar "confiar con espacios devuelve 3" rc_es $? 3
"$ADUANA" verificar "$VOL_PROPIO" --confiar Ana >/dev/null; comprobar "confiar devuelve 0" rc_es $? 0
"$ADUANA" verificar "$VOL_PROPIO" --json > "$TMP/v.json"; comprobar "firmante conocido devuelve 0" rc_es $? 0
comprobar "firmante Ana" rc_es "$(json_campo "$TMP/v.json" firma.firmante)" Ana

echo x > "$VOL_PROPIO/.DS_Store"
"$ADUANA" verificar "$VOL_PROPIO" >/dev/null; comprobar "un artefacto nuevo no altera" rc_es $? 0

cp "$VOL_PROPIO/docs/uno.txt" "$TMP/uno.bak"
echo "UNO" > "$VOL_PROPIO/docs/uno.txt"
"$ADUANA" verificar "$VOL_PROPIO" --json > "$TMP/v.json"; comprobar "modificado devuelve 2" rc_es $? 2
comprobar "detecta modificado" contiene "$TMP/v.json" '{"tipo":"modificado","ruta":"docs/uno.txt"}'
cp "$TMP/uno.bak" "$VOL_PROPIO/docs/uno.txt"

rm "$VOL_PROPIO/docs/uno.txt"
"$ADUANA" verificar "$VOL_PROPIO" --json > "$TMP/v.json"; comprobar "detecta ausente" contiene "$TMP/v.json" '{"tipo":"ausente","ruta":"docs/uno.txt"}'
cp "$TMP/uno.bak" "$VOL_PROPIO/docs/uno.txt"

echo intruso > "$VOL_PROPIO/.oculto"
"$ADUANA" verificar "$VOL_PROPIO" --json > "$TMP/v.json"; comprobar "detecta añadido oculto" contiene "$TMP/v.json" '{"tipo":"añadido","ruta":".oculto"}'
rm "$VOL_PROPIO/.oculto"

"$ADUANA" verificar "$VOL_PROPIO" >/dev/null; comprobar "restaurado vuelve a 0" rc_es $? 0
cp "$VOL_PROPIO/ADUANA-MANIFIESTO.txt" "$TMP/m.bak"
sed -i '' 's/^# fecha: .*/# fecha: 1999-01-01T00:00:00Z/' "$VOL_PROPIO/ADUANA-MANIFIESTO.txt"
"$ADUANA" verificar "$VOL_PROPIO" --json > "$TMP/v.json"; comprobar "manifiesto alterado devuelve 2" rc_es $? 2
comprobar "firma inválida" rc_es "$(json_campo "$TMP/v.json" firma.estado)" invalida
cp "$TMP/m.bak" "$VOL_PROPIO/ADUANA-MANIFIESTO.txt"

cp "$VOL_PROPIO/ADUANA-MANIFIESTO.txt" "$TMP/m.bak"
print -r -- "esto no es una línea válida" >> "$VOL_PROPIO/ADUANA-MANIFIESTO.txt"
"$ADUANA" verificar "$VOL_PROPIO" --json > "$TMP/v.json"; comprobar "línea dañada devuelve 2" rc_es $? 2
cp "$TMP/m.bak" "$VOL_PROPIO/ADUANA-MANIFIESTO.txt"
printf '\x00\x05\x16\x07' > "$VOL_PROPIO/._uno.txt"; echo x > "$VOL_PROPIO/._falso.txt"
"$ADUANA" verificar "$VOL_PROPIO" --json > "$TMP/v.json"
comprobar "un ._ falso nuevo cuenta como añadido" contiene "$TMP/v.json" '{"tipo":"añadido","ruta":"._falso.txt"}'
comprobar "un ._ AppleDouble no cuenta" no_contiene "$TMP/v.json" '._uno.txt'
rm -f "$VOL_PROPIO/._uno.txt" "$VOL_PROPIO/._falso.txt"
ln -s /etc "$VOL_PROPIO/enlace"
"$ADUANA" salida firmar "$VOL_PROPIO" --clave "$TMP/clave" >/dev/null 2>&1; comprobar "firmar se niega con enlaces" rc_es $? 3
"$ADUANA" verificar "$VOL_PROPIO" --json > "$TMP/v.json"; comprobar "un enlace nuevo cuenta como añadido" contiene "$TMP/v.json" '{"tipo":"añadido","ruta":"enlace"}'
rm "$VOL_PROPIO/enlace"
rm -rf "$VOL_PROPIO/.fseventsd"

"$ADUANA" verificar "$TMP/limpia" >/dev/null 2>&1; comprobar "sin manifiesto devuelve 3" rc_es $? 3

# =============================================================================================
print -r -- "== Salida, capacidad"

"$ADUANA" salida comprobar-capacidad "$VOL_PROPIO" --limite 8 > "$TMP/cap.txt" 2>/dev/null
comprobar "capacidad correcta devuelve 0" rc_es $? 0
VOL_PROPIO=$(punto_de_montaje "${DISCO_PROPIO}s1")
comprobar "borra sus ficheros" test -z "$(ls "$VOL_PROPIO" | grep ADUANA-CAPACIDAD)"
"$ADUANA" salida comprobar-capacidad "$TMP/limpia" >/dev/null 2>&1; comprobar "capacidad fuera de un volumen devuelve 3" rc_es $? 3

# =============================================================================================
print -r -- "== Equipo"

"$ADUANA" preparar-equipo >/dev/null; comprobar "preparar-equipo devuelve 0" rc_es $? 0
comprobar "activa DSDontWriteUSBStores" rc_es "$(defaults read "$ADUANA_DOMINIO_DS" DSDontWriteUSBStores 2>/dev/null)" 1
"$ADUANA" restaurar-equipo >/dev/null; comprobar "restaurar-equipo devuelve 0" rc_es $? 0
defaults read "$ADUANA_DOMINIO_DS" DSDontWriteUSBStores >/dev/null 2>&1; comprobar "la clave vuelve a no existir" rc_es $? 1
defaults write "$ADUANA_DOMINIO_DS" DSDontWriteUSBStores -bool false
"$ADUANA" preparar-equipo >/dev/null; "$ADUANA" restaurar-equipo >/dev/null
comprobar "y si existía, recupera su valor" rc_es "$(defaults read "$ADUANA_DOMINIO_DS" DSDontWriteUSBStores 2>/dev/null)" 0

# =============================================================================================
print -r -- "== Centinela"

cat > "$TMP/hidutil-falso" <<'EOF'
#!/bin/zsh -f
# Devuelve el teclado interno y, a partir de la tercera consulta, un teclado USB nuevo.
n=$(( $(cat "$0.n" 2>/dev/null || echo 0) + 1 )); print $n > "$0.n"
print '{"type":"device","IORegistryEntryID":100,"VendorID":0,"ProductID":0,"Transport":"FIFO","Product":"Interno"}'
(( n >= 3 )) && [[ -e "$0.nuevo" ]] && print '{"type":"device","IORegistryEntryID":200,"VendorID":1234,"ProductID":5678,"Transport":"USB","Product":"Pendrive raro"}'
exit 0
EOF
cat > "$TMP/bloqueo-falso" <<EOF
#!/bin/zsh -f
touch "$TMP/bloqueado"
EOF
chmod +x "$TMP/hidutil-falso" "$TMP/bloqueo-falso"
export ADUANA_HIDUTIL=$TMP/hidutil-falso ADUANA_BLOQUEO=$TMP/bloqueo-falso

"$ADUANA" centinela --durante 1 >/dev/null; comprobar "sin teclados nuevos devuelve 0" rc_es $? 0
comprobar "y no bloquea" test ! -e "$TMP/bloqueado"
rm -f "$TMP/hidutil-falso.n"; touch "$TMP/hidutil-falso.nuevo"
"$ADUANA" centinela --durante 5 >/dev/null; comprobar "un teclado nuevo devuelve 2" rc_es $? 2
comprobar "y bloquea la sesión" test -e "$TMP/bloqueado"
rm -f "$TMP/bloqueado"; print 5 > "$TMP/hidutil-falso.n"
"$ADUANA" centinela --aprender >/dev/null
"$ADUANA" centinela --aprender >/dev/null
comprobar "aprender guarda sin duplicar" rc_es "$(grep -c 1234:5678:USB "$ADUANA_ESTADO/teclados-conocidos.txt")" 1
rm -f "$TMP/hidutil-falso.n"
"$ADUANA" centinela --durante 2 >/dev/null; comprobar "un teclado conocido no dispara" rc_es $? 0
"$ADUANA" centinela --durante 0 >/dev/null 2>&1; comprobar "durante 0 devuelve 3" rc_es $? 3
unset ADUANA_HIDUTIL ADUANA_BLOQUEO
# En una máquina virtual de CI puede no haber ningún teclado, así que basta con que responda.
hidutil list --ndjson --matching keyboard >/dev/null 2>&1; comprobar "hidutil real responde" rc_es $? 0

# =============================================================================================
print -r -- ""
print -r -- "Resultado, $OK correctas y $KO fallidas."
(( KO == 0 ))

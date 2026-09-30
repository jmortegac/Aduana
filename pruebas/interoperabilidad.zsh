#!/bin/zsh -f
# Comprueba que un pendrive firmado con Aduana en macOS se verifica con el código de Windows, y al
# revés. El lado de Windows corre en el contenedor de pruebas (PowerShell 7 sobre Linux), así que
# hace falta Docker y haber construido la imagen con pruebas/ejecutar-docker.sh.
#
# Uso: pruebas/interoperabilidad.zsh

emulate -R zsh
setopt no_unset pipe_fail
export LC_ALL=en_US.UTF-8

RAIZ=${0:A:h:h}
IMAGEN=aduana-pruebas-windows:local
TMP=$(mktemp -d -t aduana-interop)
trap 'rm -rf "$TMP"' EXIT INT TERM
typeset -i OK=0 KO=0

comprobar() {
  local descripcion=$1 esperado=$2 obtenido=$3
  if [[ $esperado == $obtenido ]]; then (( ++OK )); print -r -- "ok      $descripcion"
  else (( ++KO )); print -r -- "FALLO   $descripcion (esperaba $esperado, obtuve $obtenido)"; fi
}

windows() {
  # La clave se copia dentro del contenedor con permisos 600, porque ssh-keygen rechaza una clave
  # privada que puedan leer otros y el usuario del contenedor no es el dueño del fichero.
  docker run --rm --network none --read-only --cap-drop ALL --security-opt no-new-privileges:true \
    --tmpfs /tmp:rw,exec --tmpfs /home/aduana:rw,uid=10001,gid=10001 -e ADUANA_ESTADO=/home/aduana/estado \
    -v "$RAIZ:/repo:ro" -v "$TMP/claves:/claves:ro" -v "$1:/datos:${2:-ro}" \
    --entrypoint pwsh "$IMAGEN" -NoLogo -NoProfile -Command \
    "Copy-Item /claves/k /tmp/k; Copy-Item /claves/k.pub /tmp/k.pub; chmod 600 /tmp/k; & /repo/windows/Aduana.ps1 ${@[3,-1]}; exit \$LASTEXITCODE" >/dev/null 2>&1
}

docker image inspect "$IMAGEN" >/dev/null 2>&1 || { print -u2 "Falta la imagen $IMAGEN. Ejecuta antes pruebas/ejecutar-docker.sh."; exit 3 }
mkdir -p "$TMP/claves" "$TMP/mac/docs" "$TMP/win/sub"
ssh-keygen -q -t ed25519 -N '' -C interop -f "$TMP/claves/k"
chmod 644 "$TMP/claves/k"

# Nombres con tilde en NFD (como los guarda macOS) y en NFC (como los guarda Windows), un oculto,
# un ._ AppleDouble y un desktop.ini decorativo, que ninguno de los dos debe meter en el manifiesto.
echo uno > "$TMP/mac/docs/uno.txt"
echo dos > "$TMP/mac/$(printf 'nin\xcc\x83o.txt')"
echo tres > "$TMP/mac/.oculto"
printf '\x00\x05\x16\x07' > "$TMP/mac/._uno.txt"
printf '[.ShellClassInfo]\r\nIconResource=x.ico,0\r\n' > "$TMP/mac/docs/desktop.ini"
echo a > "$TMP/win/sub/a.txt"
echo b > "$TMP/win/$(printf 'ni\xc3\xb1a.txt')"
printf '\x00\x05\x16\x07' > "$TMP/win/._a.txt"
chmod -R a+rwX "$TMP/mac" "$TMP/win"

cp "$TMP/claves/k" "$TMP/k-mac"; chmod 600 "$TMP/k-mac"; cp "$TMP/claves/k.pub" "$TMP/k-mac.pub"
"$RAIZ/macos/aduana" salida firmar "$TMP/mac" --clave "$TMP/k-mac" >/dev/null
comprobar "macOS firma" 0 $?
windows "$TMP/mac" ro verificar /datos
comprobar "Windows verifica lo firmado en macOS (firmante desconocido)" 1 $?
echo cambio >> "$TMP/mac/docs/uno.txt"
windows "$TMP/mac" ro verificar /datos
comprobar "Windows detecta un cambio en lo firmado en macOS" 2 $?

windows "$TMP/win" rw salida firmar /datos --clave /tmp/k
comprobar "Windows firma" 0 $?
"$RAIZ/macos/aduana" verificar "$TMP/win" >/dev/null
comprobar "macOS verifica lo firmado en Windows (firmante desconocido)" 1 $?
echo cambio >> "$TMP/win/sub/a.txt"
"$RAIZ/macos/aduana" verificar "$TMP/win" >/dev/null
comprobar "macOS detecta un cambio en lo firmado en Windows" 2 $?

print -r -- ""
print -r -- "Resultado, $OK correctas y $KO fallidas."
(( KO == 0 ))

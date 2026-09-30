# Órdenes de salida, para preparar un pendrive propio antes de prestarlo.

typeset -ga EXT_IMAGEN=(jpg jpeg heic heif png tif tiff)
typeset -ga EXT_ODF=(odt ods odp odg)
# Artefactos que `limpiar` borra. Se conservan .metadata_never_index y .fseventsd/no_log, que
# pone `preparar` para que macOS no vuelva a llenar el pendrive, y System Volume Information,
# que Windows protege y recrea.
typeset -ga BORRABLES=(.DS_Store .Spotlight-V100 .Trashes .TemporaryItems .apdisk
  .DocumentRevisions-V100 Thumbs.db ehthumbs.db '$RECYCLE.BIN' RECYCLER)

# ---------------------------------------------------------------------------------------------
# salida preparar

discos_protegidos() {
  local punto d
  for punto in / /System/Volumes/Data; do
    d=$(diskutil info -plist "$punto" 2>/dev/null | ayudante plist-campos ParentWholeDisk)
    [[ -n $d ]] && print -r -- "$d"
    diskutil info -plist "$punto" 2>/dev/null | ayudante almacenes-apfs | while IFS= read -r d; do
      [[ -n $d ]] && diskutil info -plist "$d" 2>/dev/null | ayudante plist-campos ParentWholeDisk
    done
  done
}

higiene_macos() {
  local punto=$1
  touch "$punto/.metadata_never_index" 2>/dev/null
  mkdir -p "$punto/.fseventsd" 2>/dev/null && touch "$punto/.fseventsd/no_log" 2>/dev/null
  rm -rf "$punto/.Spotlight-V100" "$punto/.Trashes" "$punto/.TemporaryItems" 2>/dev/null
  (( EUID == 0 )) && mdutil -i off "$punto" >/dev/null 2>&1
  return 0
}

orden_salida_preparar() {
  [[ -n ${ARGS[1]:-} ]] || { fallo "falta el disco. «aduana montar» sin argumentos lista los externos."; return $R_ERROR }
  local disco=$(normalizar_disco "${ARGS[1]}") nombre=${OPT[nombre]:-ADUANA} respuesta punto
  local -a v protegidos
  v=("${(@f)$(diskutil info -plist "$disco" 2>/dev/null | ayudante plist-campos Internal WholeDisk MediaName TotalSize)}")
  [[ ${v[1]:-} == false ]] || { fallo "$disco no existe o es un disco interno. Aduana nunca borra discos internos."; return $R_ERROR }
  [[ ${v[2]:-} == true ]] || { fallo "indica el disco entero, como disk4, no una partición."; return $R_ERROR }
  protegidos=("${(@f)$(discos_protegidos)}")
  (( ${protegidos[(Ie)$disco]} )) && { fallo "$disco contiene el sistema en marcha. No lo borro."; return $R_ERROR }
  [[ $nombre =~ '^[A-Za-z0-9_-]{1,11}$' ]] || { fallo "el nombre debe tener de 1 a 11 letras sin tildes, números, guiones o guiones bajos."; return $R_ERROR }

  if [[ -z ${OPT[si]:-} ]]; then
    info "${C_ROJO}${C_NEGRITA}Vas a borrar todo el contenido de $disco${C_FIN}, ${v[3]:-sin nombre}, $(( ${v[4]:-0} / 1000000000 )) GB."
    print -rn -- "Escribe $disco para confirmar: "
    read -r respuesta < /dev/tty || respuesta=''
    [[ $respuesta == $disco ]] || { fallo "no coincide. No he borrado nada."; return $R_ERROR }
  fi

  if [[ -n ${OPT[borrado-completo]:-} ]]; then
    info "Sobrescribiendo el disco entero con ceros. Puede tardar mucho."
    diskutil zeroDisk "$disco" >/dev/null || { fallo "el borrado completo ha fallado."; return $R_ERROR }
  fi
  diskutil eraseDisk ExFAT "$nombre" MBRFormat "$disco" >/dev/null || { fallo "diskutil no ha podido formatear $disco."; return $R_ERROR }
  punto=$(diskutil info -plist "${disco}s1" 2>/dev/null | ayudante plist-campos MountPoint)
  [[ -n $punto ]] && higiene_macos "$punto"

  info "Hecho. $disco tiene ahora una partición exFAT llamada $nombre${punto:+, montada en $punto}."
  if [[ -z ${OPT[borrado-completo]:-} ]]; then
    info "El formateo rápido no sobrescribe los datos anteriores. Si eran delicados, repite con --borrado-completo,"
    info "sabiendo que en memoria flash ni eso lo garantiza del todo."
  fi
  return $R_OK
}

# ---------------------------------------------------------------------------------------------
# salida limpiar

xml_valor() {
  local xml=$1 etiqueta=$2
  print -r -- "$xml" | sed -nE "s#.*<$etiqueta>([^<]*)</$etiqueta>.*#\\1#p" | head -1
}

# Metadatos de un documento OOXML u ODF. Imprime «campo<TAB>valor» por línea.
metadatos_zip() {
  local f=$1 ext=$2 core app meta
  if (( ${EXT_ODF[(Ie)$ext]} )); then
    meta=$(unzip -p "$f" meta.xml 2>/dev/null) || return 0
    local e
    for e in meta:initial-creator dc:creator; do
      local x=$(xml_valor "$meta" $e)
      [[ -n $x ]] && print -r -- "autor"$'\t'"$x"
    done
  else
    core=$(unzip -p "$f" docProps/core.xml 2>/dev/null) || return 0
    app=$(unzip -p "$f" docProps/app.xml 2>/dev/null)
    local x
    x=$(xml_valor "$core" dc:creator); [[ -n $x ]] && print -r -- "autor"$'\t'"$x"
    x=$(xml_valor "$core" cp:lastModifiedBy); [[ -n $x ]] && print -r -- "último en modificarlo"$'\t'"$x"
    x=$(xml_valor "$app" Company); [[ -n $x ]] && print -r -- "empresa"$'\t'"$x"
    x=$(xml_valor "$app" Manager); [[ -n $x ]] && print -r -- "responsable"$'\t'"$x"
  fi
  return 0
}

# Vacía esos campos reescribiendo las piezas XML dentro del zip, sin tocar el resto del documento.
limpiar_zip() {
  local f=${1:A} ext=$2 tmp=$(mktemp -d -t aduana) pieza
  local -a piezas etiquetas
  if (( ${EXT_ODF[(Ie)$ext]} )); then
    piezas=(meta.xml) etiquetas=(meta:initial-creator dc:creator)
  else
    piezas=(docProps/core.xml docProps/app.xml) etiquetas=(dc:creator cp:lastModifiedBy Company Manager)
  fi
  (
    cd "$tmp" || exit 1
    for pieza in $piezas; do
      unzip -o -q "$f" "$pieza" 2>/dev/null || continue
      local e
      for e in $etiquetas; do sed -i '' -E "s#<$e>[^<]*</$e>#<$e></$e>#g" "$pieza"; done
      zip -q "$f" "$pieza" || exit 1
    done
  )
  local rc=$?
  rm -rf "$tmp"
  return $rc
}

orden_salida_limpiar() {
  local raiz nombre f rel ext solo=${OPT[solo-informe]:-}
  requiere_ruta "${ARGS[1]:-}" || return
  raiz=$(absoluta "${ARGS[1]}")
  [[ -d $raiz ]] || { fallo "$(visible "$raiz") no es una carpeta ni un volumen."; return $R_ERROR }

  # 1. Metadatos personales.
  local exiftool=$(command -v exiftool 2>/dev/null || true)
  local -i con_datos=0 limpiados=0 pendientes=0
  local campo valor lineas
  while IFS= read -r -d '' f; do
    rel=${f#$raiz/}
    ext=''; [[ ${f:t} == *.* ]] && ext=${(L)f:e}
    lineas=''
    if [[ -n ${EXT_OFFICE[$ext]:-} || ${EXT_ODF[(Ie)$ext]} -gt 0 ]] && [[ $(head -c 2 "$f" 2>/dev/null) == PK ]]; then
      lineas=$(metadatos_zip "$f" "$ext")
    elif (( ${EXT_IMAGEN[(Ie)$ext]} )); then
      lineas=$(ayudante imagen-leer "$f" 2>/dev/null | grep -v '^error' || true)
    elif [[ $ext == pdf ]]; then
      lineas=$(ayudante pdf-leer "$f" 2>/dev/null | grep -v '^error' || true)
    fi
    [[ -n $lineas ]] || continue
    (( ++con_datos ))
    info ""
    info "$(visible "$rel")"
    while IFS=$'\t' read -r campo valor; do info "  $campo, $(visible "$valor")"; done <<< "$lineas"
    [[ -n $solo ]] && continue

    if [[ $ext == pdf ]]; then
      if [[ -n $exiftool ]] && "$exiftool" -q -all= -overwrite_original "$f" >/dev/null 2>&1; then
        (( ++limpiados ))
        info "  limpiado con exiftool. En un PDF sus cambios son reversibles, así que si es delicado"
        info "  imprímelo a un PDF nuevo desde Vista Previa."
      else
        (( ++pendientes ))
        info "  sin limpiar, hace falta exiftool (brew install exiftool) o imprimirlo a un PDF nuevo."
      fi
    elif (( ${EXT_IMAGEN[(Ie)$ext]} )); then
      if [[ $(ayudante imagen-limpiar "$f" 2>/dev/null) == ok ]]; then (( ++limpiados )); info "  limpiado"
      else (( ++pendientes )); info "  no he podido limpiarlo"; fi
    else
      if limpiar_zip "$f" "$ext"; then (( ++limpiados )); info "  limpiado"
      else (( ++pendientes )); info "  no he podido limpiarlo"; fi
    fi
  done < <(find -x "$raiz" -mindepth 1 \( -name '._*' -o -name .fseventsd \) -prune -o -type f -print0 2>/dev/null)

  # 2. Artefactos de sistema, al final, porque al reescribir un documento macOS vuelve a crear su
  # fichero ._ en los volúmenes que no son APFS.
  local -a cond=('(') borrables
  for nombre in $BORRABLES; do cond+=(-iname "$nombre" -o); done
  cond+=(-name '._*' ')')
  while IFS= read -r -d '' f; do borrables+=("$f"); done < <(find -x "$raiz" -mindepth 1 "${cond[@]}" -prune -print0 2>/dev/null)
  # Un desktop.ini sin CLSID es solo decoración de Windows. Con CLSID puede lanzar código, así que
  # no se borra a ciegas: se avisa para que lo revises.
  local -a con_clsid
  while IFS= read -r -d '' f; do
    if desktop_ini_con_clsid "$f"; then con_clsid+=("$f"); else borrables+=("$f"); fi
  done < <(find -x "$raiz" -mindepth 1 -type f -iname desktop.ini -print0 2>/dev/null)
  for f in $con_clsid; do aviso "$(visible "${f#$raiz/}") lleva un CLSID. No lo borro, revísalo tú."; done
  if [[ -z $solo ]]; then
    dot_clean -m "$raiz" 2>/dev/null
    for f in $borrables; do rm -rf "$f"; done
    info "Borrados ${#borrables} ficheros de sistema."
  else
    info "Hay ${#borrables} ficheros de sistema que se borrarían."
    for f in $borrables; do info "  $(visible "${f#$raiz/}")"; done
  fi

  info ""
  if (( ! con_datos )); then
    info "No he encontrado metadatos personales en documentos, imágenes ni PDF."
  elif [[ -n $solo ]]; then
    info "$con_datos ficheros con metadatos personales. Sin --solo-informe, Aduana los limpia."
  else
    info "$con_datos ficheros con metadatos personales, $limpiados limpiados y $pendientes pendientes."
  fi
  (( pendientes )) && return $R_SOSPECHOSO
  return $R_OK
}

# ---------------------------------------------------------------------------------------------
# salida comprobar-capacidad
#
# Algunos pendrives baratos dicen tener más capacidad de la que tienen y sobrescriben en círculo lo
# ya escrito. Se detecta escribiendo datos distintos en cada bloque, vaciando la caché al desmontar
# y comparando al releer. Los datos salen de AES-128-CTR con una clave por fichero, que es rápido,
# determinista y no se repite.

flujo_capacidad() {
  setopt local_options no_pipe_fail
  local semilla=$1 indice=$2 tam=$3 clave
  clave=$(printf 'aduana-%s-%d' "$semilla" "$indice" | shasum -a 256 | cut -c1-32)
  /usr/bin/openssl enc -aes-128-ctr -K "$clave" -iv 00000000000000000000000000000000 -nosalt -in /dev/zero 2>/dev/null | head -c "$tam"
}

orden_salida_capacidad() {
  local raiz dispositivo semilla punto
  requiere_ruta "${ARGS[1]:-}" || return
  raiz=$(absoluta "${ARGS[1]}")
  local -a v
  v=("${(@f)$(diskutil info -plist "$raiz" 2>/dev/null | ayudante plist-campos MountPoint DeviceIdentifier Internal)}")
  [[ ${v[1]:-} == "$raiz" ]] || { fallo "indica el punto de montaje del pendrive, como /Volumes/NOMBRE."; return $R_ERROR }
  [[ ${v[3]:-} == false ]] || { fallo "es un disco interno. Esta prueba es para pendrives."; return $R_ERROR }
  dispositivo=${v[2]}

  local -i libre gib=1073741824 mib=1048576 objetivo n i tam escrito=0 verificado=0
  libre=$(( $(df -k "$raiz" | awk 'NR==2 {print $4}') * 1024 ))
  objetivo=$(( libre - mib ))
  [[ -n ${OPT[limite]:-} ]] && (( ${OPT[limite]} * mib < objetivo )) && objetivo=$(( ${OPT[limite]} * mib ))
  (( objetivo > 0 )) || { fallo "no queda espacio libre para la prueba."; return $R_ERROR }
  n=$(( (objetivo + gib - 1) / gib ))
  semilla=$(/usr/bin/openssl rand -hex 8)

  info "Voy a escribir $(( objetivo / mib )) MB en $n ficheros y después a releerlos."
  local -a tamanos
  for (( i = 1; i <= n; i++ )); do
    tam=$(( i < n ? gib : objetivo - (n - 1) * gib ))
    tamanos+=($tam)
    print -ru2 -- "Escribiendo $i de $n"
    if ! flujo_capacidad "$semilla" $i $tam > "$raiz/ADUANA-CAPACIDAD-$(printf %04d $i).bin"; then
      aviso "la escritura del fichero $i ha fallado, sigo con lo escrito."
    fi
    (( escrito += tam ))
  done
  sync

  # Desmontar y volver a montar obliga a leer del pendrive y no de la caché del sistema.
  diskutil unmount "$dispositivo" >/dev/null 2>&1 && diskutil mount "$dispositivo" >/dev/null 2>&1 || \
    aviso "no he podido desmontar y volver a montar, la lectura puede venir de la caché y no ser fiable."
  punto=$(diskutil info -plist "$dispositivo" 2>/dev/null | ayudante plist-campos MountPoint)
  [[ -n $punto ]] || { fallo "el pendrive no ha vuelto a montarse. Los ficheros ADUANA-CAPACIDAD siguen en él."; return $R_ERROR }

  local -a fallidos
  for (( i = 1; i <= n; i++ )); do
    print -ru2 -- "Comprobando $i de $n"
    f="$punto/ADUANA-CAPACIDAD-$(printf %04d $i).bin"
    if cmp -s "$f" <(flujo_capacidad "$semilla" $i ${tamanos[i]}); then (( verificado += ${tamanos[i]} ))
    else fallidos+=($i); fi
    rm -f "$f"
  done

  info "Escritos $(( escrito / mib )) MB, verificados $(( verificado / mib )) MB."
  if (( ${#fallidos} )); then
    info "${C_ROJO}${C_NEGRITA}El pendrive no devuelve lo que se escribió en él${C_FIN} (ficheros ${(j:, :)fallidos})."
    info "O miente sobre su capacidad o está dañado. No guardes en él nada que te importe."
    return $R_PELIGROSO
  fi
  info "${C_VERDE}Todo lo escrito se ha leído igual.${C_FIN}"
  return $R_OK
}

# ---------------------------------------------------------------------------------------------
# salida cifrar

orden_salida_cifrar() {
  local carpeta salida bin
  requiere_ruta "${ARGS[1]:-}" || return
  carpeta=$(absoluta "${ARGS[1]}")
  salida=${OPT[salida]:-${carpeta%/}.7z}
  [[ -e $salida ]] && { fallo "$(visible "$salida") ya existe."; return $R_ERROR }
  bin=$(command -v 7zz 2>/dev/null || command -v 7z 2>/dev/null) || {
    fallo "hace falta 7-Zip. Con Homebrew, brew install sevenzip. Para cifrar un pendrive entero, VeraCrypt."
    return $R_ERROR
  }
  info "7-Zip te pedirá la contraseña. Usa una larga y compártela por otro canal, nunca en el propio pendrive."
  # -mhe=on cifra también los nombres de los ficheros, no solo su contenido.
  "$bin" a -t7z -mhe=on -p "$salida" "$carpeta" || { fallo "7-Zip no ha podido cifrar."; return $R_ERROR }
  info "Cifrado en $(visible "$salida")."
  return $R_OK
}

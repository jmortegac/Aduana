# Orden `copiar`: copia lo que no es peligroso y le pone la marca de cuarentena de macOS.
#
# Lo que llega de internet lleva el atributo com.apple.quarantine, y por eso Gatekeeper pregunta
# antes de abrir una aplicación. Lo que se copia de un pendrive no lo lleva, así que el sistema se
# fía. Aduana lo añade al copiar para que Gatekeeper vuelva a hacer su trabajo.

typeset -ga EXT_DESINFECTABLES=(pdf doc docx xls xlsx ppt pptx odt ods odp rtf jpg jpeg png gif bmp tif tiff)

valor_cuarentena() { printf '0081;%x;Aduana;' "$(date +%s)" }

# Deja en REPLY una ruta de destino que no exista, añadiendo « (2)», « (3)»... si hace falta.
destino_libre() {
  local ruta=$1 base ext n=2
  if [[ ! -e $ruta && ! -L $ruta ]]; then REPLY=$ruta; return; fi
  if [[ ${ruta:t} == *.* ]]; then base=${ruta:r} ext=".${ruta:e}"; else base=$ruta ext=''; fi
  while [[ -e "$base ($n)$ext" ]]; do (( ++n )); done
  REPLY="$base ($n)$ext"
}

dangerzone_cli() {
  local c
  for c in /Applications/Dangerzone.app/Contents/MacOS/dangerzone-cli $(command -v dangerzone-cli 2>/dev/null); do
    [[ -x $c ]] && { print -r -- "$c"; return 0 }
  done
  return 1
}

orden_copiar() {
  local origen destino dz=''
  requiere_ruta "${ARGS[1]:-}" || return
  [[ -n ${ARGS[2]:-} ]] || { fallo "falta el destino. Uso, aduana copiar <volumen> <destino>."; return $R_ERROR }
  origen=$(absoluta "${ARGS[1]}")
  destino=$(absoluta "${ARGS[2]}")
  [[ -d $origen ]] || { fallo "$(visible "$origen") no es una carpeta ni un volumen."; return $R_ERROR }
  [[ $destino == $origen || $destino/ == $origen/* ]] && { fallo "el destino no puede estar dentro del pendrive."; return $R_ERROR }
  if [[ -n ${OPT[desinfectar]:-} ]]; then
    dz=$(dangerzone_cli) || { fallo "--desinfectar necesita Dangerzone, que se descarga en https://dangerzone.rocks."; return $R_ERROR }
  fi

  analizar "$origen"
  mkdir -p "$destino" || { fallo "no puedo crear $(visible "$destino")."; return $R_ERROR }

  # Primer motivo peligroso de cada ruta, para explicar por qué se omite.
  local -A motivo
  local i
  for (( i = 1; i <= ${#H_RUTA}; i++ )); do
    [[ ${H_NIVEL[i]} == peligroso && -z ${motivo[${H_RUTA[i]}]:-} ]] && motivo[${H_RUTA[i]}]="${H_REGLA[i]}, ${H_DETALLE[i]}"
  done

  local cuarentena=$(valor_cuarentena)
  local rel tipo ext dst previo
  local -a omitidas
  local -a omitidos_ruta omitidos_motivo avisos copias
  local -i copiados=0 marcados=0 artefactos=0
  for (( i = 1; i <= ${#E_REL}; i++ )); do
    rel=${E_REL[i]} tipo=${E_TIPO[i]}
    # Lo que cuelga de una carpeta omitida se omite con ella. Son varias, y los ._ que no son
    # AppleDouble llegan al final del recorrido, así que no basta con recordar la última.
    for previo in $omitidas; do [[ $rel == $previo/* ]] && continue 2; done
    case $tipo in
      a) (( ++artefactos )); continue ;;
      l) omitidos_ruta+=("$rel"); omitidos_motivo+=("enlace simbólico, Aduana no lo sigue"); continue ;;
    esac
    if [[ -n ${RUTA_PELIGROSA[$rel]:-} && -z ${OPT[incluir-peligrosos]:-} ]]; then
      omitidos_ruta+=("$rel"); omitidos_motivo+=("${motivo[$rel]:-peligroso}")
      [[ $tipo == d ]] && omitidas+=("$rel")
      continue
    fi
    ext=''; [[ ${rel:t} == *.* ]] && ext=${(L)rel:e}
    if [[ $tipo == d ]]; then
      if (( ${PAQUETES_MACOS[(Ie)$ext]} )); then
        # Un paquete de macOS se copia entero y se marca en la raíz, que es donde mira Gatekeeper.
        destino_libre "$destino/$rel"; dst=$REPLY
        if cp -R -X "$origen/$rel" "$dst" && xattr -w com.apple.quarantine "$cuarentena" "$dst"; then
          (( ++copiados, ++marcados ))
        else
          avisos+=("No he podido copiar $rel")
        fi
        omitidas+=("$rel")
      else
        mkdir -p "$destino/$rel"
      fi
      continue
    fi

    [[ $rel == */* && ! -d $destino/${rel:h} ]] && mkdir -p "$destino/${rel:h}"
    if [[ -n $dz && -n $ext ]] && (( ${EXT_DESINFECTABLES[(Ie)$ext]} )); then
      destino_libre "$destino/${rel:r}-seguro.pdf"; dst=$REPLY
      if "$dz" --output-filename "$dst" "$origen/$rel" >/dev/null 2>&1; then
        (( ++copiados ))
      else
        avisos+=("Dangerzone no ha podido convertir $rel, no lo he copiado")
      fi
      continue
    fi

    destino_libre "$destino/$rel"; dst=$REPLY
    # -X no copia atributos extendidos ni forks de recursos del pendrive.
    if cp -X "$origen/$rel" "$dst"; then
      (( ++copiados ))
      copias+=("$dst")
    else
      avisos+=("No he podido copiar $rel")
    fi
  done

  # Permisos y marca de cuarentena en bloque, que con miles de ficheros es mucho más rápido.
  # En FAT y exFAT todo parece ejecutable, y la copia no hereda ese permiso.
  if (( ${#copias} )); then
    printf '%s\0' "${copias[@]}" | xargs -0 chmod 600
    if printf '%s\0' "${copias[@]}" | xargs -0 xattr -w com.apple.quarantine "$cuarentena" 2>/dev/null; then
      (( marcados += ${#copias} ))
    else
      local c
      for c in $copias; do
        if xattr -w com.apple.quarantine "$cuarentena" "$c" 2>/dev/null; then (( ++marcados ))
        else avisos+=("No he podido marcar ${c#$destino/}, el destino quizá no admite atributos extendidos"); fi
      done
    fi
  fi

  if [[ -n ${OPT[json]:-} ]]; then
    print -rn -- "{\"aduana\":$(json_cadena $ADUANA_VERSION),\"orden\":\"copiar\",\"origen\":$(json_cadena "$origen"),"
    print -rn -- "\"destino\":$(json_cadena "$destino"),\"fecha\":$(json_cadena "$(fecha_iso)"),\"sistema\":\"macos\","
    print -rn -- "\"copiados\":$copiados,\"marcados\":$marcados,\"omitidos\":["
    for (( i = 1; i <= ${#omitidos_ruta}; i++ )); do
      (( i > 1 )) && print -rn -- ','
      print -rn -- "{\"ruta\":$(json_cadena "${omitidos_ruta[i]}"),\"motivo\":$(json_cadena "${omitidos_motivo[i]}")}"
    done
    print -rn -- '],"avisos":['
    for (( i = 1; i <= ${#avisos}; i++ )); do
      (( i > 1 )) && print -rn -- ','
      print -rn -- "$(json_cadena "${avisos[i]}")"
    done
    print -r -- ']}'
  else
    info "Copiados $copiados elementos a $(visible "$destino"), $marcados con marca de cuarentena."
    (( artefactos )) && info "Omitidos $artefactos ficheros de sistema."
    if (( ${#omitidos_ruta} )); then
      info ""
      info "${C_ROJO}${C_NEGRITA}No copiados (${#omitidos_ruta})${C_FIN}"
      for (( i = 1; i <= ${#omitidos_ruta}; i++ )); do
        info "  $(visible "${omitidos_ruta[i]}")"
        info "    $(visible "${omitidos_motivo[i]}")"
      done
      info ""
      info "Si de verdad los necesitas, --incluir-peligrosos los copia igualmente con la marca."
    fi
    for i in $avisos; do aviso "$(visible "$i")."; done
  fi
  (( ${#avisos} )) && return $R_ERROR
  return $R_OK
}

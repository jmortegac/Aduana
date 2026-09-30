# Órdenes `salida firmar` y `verificar`: manifiesto de SHA-256 firmado con una clave SSH.
#
# ssh-keygen -Y viene con macOS y con Windows 10 y 11, así que las dos partes pueden firmar y
# verificar sin instalar nada. El espacio de nombres «aduana» impide reutilizar la firma para otra
# cosa, como un commit o un correo.

typeset -g MANIFIESTO=ADUANA-MANIFIESTO.txt
typeset -g FIRMA_MANIFIESTO=ADUANA-MANIFIESTO.txt.sig
typeset -g CLAVE_PUBLICA=ADUANA-CLAVE.pub

typeset -gA M_HASH
typeset -gi M_ENLACES=0 M_SALTOS=0

# Lista los ficheros que entran en el manifiesto con su hash, con las rutas en NFC. macOS puede
# guardar los nombres descompuestos (NFD) y Windows compuestos (NFC); normalizando, el mismo nombre
# coincide en los dos sistemas.
listar_para_manifiesto() {
  local raiz=$1 p rel
  local -a poda rutas relativas nfc
  M_HASH=() M_ENLACES=0 M_SALTOS=0
  # Los paquetes de macOS se podan en la inspección, pero aquí hay que firmar su contenido.
  poda=("${(@0)$(condiciones_poda sin-paquetes)}")
  poda=(${poda:#})

  local -a candidatos_ad
  while IFS= read -r -d '' p; do
    rel=${p#$raiz/}
    [[ $rel == ($MANIFIESTO|$FIRMA_MANIFIESTO|$CLAVE_PUBLICA) ]] && continue
    # desktop.ini sin CLSID y los ._ AppleDouble son artefactos, igual que en la inspección y en
    # Windows. Si no coincidieran, un pendrive firmado en un sistema fallaría al verificar en el otro.
    if [[ ! -L $p && ${(L)p:t} == desktop.ini ]] && ! desktop_ini_con_clsid "$p"; then continue; fi
    if [[ ! -L $p ]] && es_prefijo_artefacto "${p:t}"; then candidatos_ad+=("$p"); continue; fi
    [[ $rel == *[$'\n\r']* ]] && (( ++M_SALTOS ))
    rutas+=("$p"); relativas+=("$rel")
  done < <(find -x "$raiz" -mindepth 1 "${poda[@]}" -prune -o \( -type f -o -type l \) -print0 2>/dev/null)

  if (( ${#candidatos_ad} )); then
    local -a magias_ad
    local j
    magias_ad=("${(@f)$(printf '%s\0' "${candidatos_ad[@]}" | ayudante magias)}")
    for (( j = 1; j <= ${#candidatos_ad}; j++ )); do
      [[ ${magias_ad[j]:-} == 00051607* ]] && continue
      rutas+=("${candidatos_ad[j]}"); relativas+=("${candidatos_ad[j]#$raiz/}")
    done
  fi

  (( ${#relativas} )) || return 0
  nfc=("${(@0)$(printf '%s\0' "${relativas[@]}" | iconv -f UTF-8-MAC -t UTF-8)}")
  local i
  for (( i = 1; i <= ${#rutas}; i++ )); do
    if [[ -L ${rutas[i]} ]]; then
      (( ++M_ENLACES ))
      M_HASH[${nfc[i]}]=enlace-simbolico
    else
      M_HASH[${nfc[i]}]=$(shasum -a 256 < "${rutas[i]}" | cut -d' ' -f1)
    fi
  done
}

orden_salida_firmar() {
  local raiz clave publica huella
  requiere_ruta "${ARGS[1]:-}" || return
  raiz=$(absoluta "${ARGS[1]}")
  clave=${OPT[clave]:-}
  [[ -n $clave ]] || { fallo "falta --clave con tu clave privada SSH, por ejemplo ~/.ssh/id_ed25519."; return $R_ERROR }
  [[ -f $clave ]] || { fallo "no existe la clave $(visible "$clave")."; return $R_ERROR }

  listar_para_manifiesto "$raiz"
  (( M_ENLACES )) && { fallo "hay $M_ENLACES enlaces simbólicos en el volumen. Quítalos antes de firmar."; return $R_ERROR }
  (( M_SALTOS )) && { fallo "hay nombres con saltos de línea, que el manifiesto no puede representar."; return $R_ERROR }

  local tmp=$(mktemp -d -t aduana)
  if [[ -f $clave.pub ]]; then
    publica=$clave.pub
  else
    publica=$tmp/clave.pub
    ssh-keygen -y -f "$clave" > "$publica" || { rm -rf "$tmp"; fallo "no he podido sacar la clave pública."; return $R_ERROR }
  fi

  # Las rutas van en el orden de sus bytes UTF-8. El separador \1 no aparece en un hash.
  {
    print -r -- "# Aduana manifiesto v1"
    print -r -- "# fecha: $(fecha_iso)"
    local rel linea
    for rel in ${(k)M_HASH}; do printf '%s\1%s\0' "$rel" "${M_HASH[$rel]}"; done |
      LC_ALL=C sort -z | while IFS= read -r -d '' linea; do
        print -r -- "${linea##*$'\1'}  ${linea%$'\1'*}"
      done
  } > "$tmp/$MANIFIESTO"

  # Se firma fuera del volumen y solo se copia si la firma sale bien, para no dejar nunca un
  # manifiesto sin firma ni destruir uno anterior que fuera bueno.
  if ! ssh-keygen -q -Y sign -f "$clave" -n aduana "$tmp/$MANIFIESTO" 2>/dev/null; then
    rm -rf "$tmp"; fallo "ssh-keygen no ha podido firmar. El volumen no ha cambiado."; return $R_ERROR
  fi
  if ! { cp "$tmp/$MANIFIESTO" "$raiz/$MANIFIESTO" && cp "$tmp/$FIRMA_MANIFIESTO" "$raiz/$FIRMA_MANIFIESTO" &&
         cp "$publica" "$raiz/$CLAVE_PUBLICA" }; then
    rm -rf "$tmp"; fallo "no he podido escribir el manifiesto en el volumen."; return $R_ERROR
  fi
  huella=$(ssh-keygen -lf "$publica" | cut -d' ' -f2)
  rm -rf "$tmp"

  info "Firmados ${#M_HASH} ficheros en $(visible "$raiz")."
  info "Huella de tu clave, $huella"
  info "Díselo a quien reciba el pendrive por otro canal, en persona o por teléfono, para que la"
  info "compare con la que le enseñe «aduana verificar»."
  return $R_OK
}

orden_verificar() {
  local raiz firmantes tmp huella tipo material estado=invalida firmante='' linea h r
  requiere_ruta "${ARGS[1]:-}" || return
  raiz=$(absoluta "${ARGS[1]}")
  firmantes=${OPT[firmantes]:-$CONFIG_DIR/firmantes}
  [[ -f $raiz/$MANIFIESTO ]] || { fallo "no hay $MANIFIESTO en $(visible "$raiz"). Este pendrive no se preparó con Aduana."; return $R_ERROR }
  if [[ -n ${OPT[confiar]:-} && ${OPT[confiar]} == *[[:space:],\"\'*?]* ]]; then
    fallo "el nombre de --confiar no puede llevar espacios, comas, comillas, asteriscos ni interrogaciones."
    return $R_ERROR
  fi

  tmp=$(mktemp -d -t aduana)
  if [[ -f $raiz/$FIRMA_MANIFIESTO && -f $raiz/$CLAVE_PUBLICA ]]; then
    read -r tipo material _ < "$raiz/$CLAVE_PUBLICA"
    print -r -- "aduana-desconocido $tipo $material" > "$tmp/permitidos"
    if ssh-keygen -Y verify -f "$tmp/permitidos" -I aduana-desconocido -n aduana \
        -s "$raiz/$FIRMA_MANIFIESTO" < "$raiz/$MANIFIESTO" >/dev/null 2>&1; then
      estado=firmante-desconocido
      huella=$(ssh-keygen -lf "$raiz/$CLAVE_PUBLICA" 2>/dev/null | cut -d' ' -f2)
      if [[ -f $firmantes ]]; then
        while IFS= read -r linea; do
          local -a campos=(${(z)linea})
          (( ${campos[(Ie)$material]} )) && { estado=valida; firmante=${campos[1]}; break }
        done < "$firmantes"
      fi
    fi
  fi
  rm -rf "$tmp"

  # Qué ha cambiado desde la firma.
  local -A esperado
  local -i danado=0
  while IFS= read -r linea; do
    [[ $linea == \#* || -z $linea ]] && continue
    # Una línea que no sea «hash, dos espacios, ruta» invalida el manifiesto entero.
    if [[ $linea != [0-9a-f](#c64)'  '?* ]]; then danado=1; continue; fi
    h=${linea[1,64]}; r=${linea[67,-1]}
    esperado[$r]=$h
  done < "$raiz/$MANIFIESTO"
  listar_para_manifiesto "$raiz"

  # Los cambios salen ordenados por los bytes de la ruta, como en Windows.
  local -a c_tipo c_ruta
  local registro
  local -a pares
  pares=("${(@0)$(
    {
      for r in ${(k)esperado}; do
        if (( ! ${+M_HASH[$r]} )); then printf '%s\1%s\0' "$r" ausente
        elif [[ ${M_HASH[$r]} != ${esperado[$r]} ]]; then printf '%s\1%s\0' "$r" modificado; fi
      done
      for r in ${(k)M_HASH}; do
        (( ${+esperado[$r]} )) || printf '%s\1%s\0' "$r" añadido
      done
    } | LC_ALL=C sort -z | while IFS= read -r -d '' registro; do
      print -rn -- "${registro%$'\1'*}"$'\0'"${registro##*$'\1'}"$'\0'
    done
  )}")
  pares=("${(@)pares:#}")
  local k
  for (( k = 1; k + 1 <= ${#pares}; k += 2 )); do c_ruta+=("${pares[k]}"); c_tipo+=("${pares[k+1]}"); done

  local v=intacto
  [[ $estado == invalida ]] || (( danado || ${#c_tipo} )) && v=alterado

  if [[ $v == intacto && -n ${OPT[confiar]:-} && $estado == firmante-desconocido ]]; then
    mkdir -p "${firmantes:h}"
    print -r -- "${OPT[confiar]} $tipo $material" >> "$firmantes"
    estado=valida firmante=${OPT[confiar]}
    info "Guardada la clave de $firmante en $(visible "$firmantes")."
  fi

  local i
  if [[ -n ${OPT[json]:-} ]]; then
    print -rn -- "{\"aduana\":$(json_cadena $ADUANA_VERSION),\"orden\":\"verificar\",\"ruta\":$(json_cadena "$raiz"),"
    print -rn -- "\"fecha\":$(json_cadena "$(fecha_iso)"),\"sistema\":\"macos\","
    print -rn -- "\"firma\":{\"estado\":$(json_cadena $estado),\"firmante\":$(json_cadena "$firmante"),\"huella\":$(json_cadena "${huella:-}")},"
    print -rn -- '"cambios":['
    for (( i = 1; i <= ${#c_tipo}; i++ )); do
      (( i > 1 )) && print -rn -- ','
      print -rn -- "{\"tipo\":$(json_cadena "${c_tipo[i]}"),\"ruta\":$(json_cadena "${c_ruta[i]}")}"
    done
    print -r -- "],\"veredicto\":$(json_cadena $v)}"
  else
    case $estado in
      valida) info "${C_VERDE}Firma válida${C_FIN} de $(visible "$firmante"), huella $huella." ;;
      firmante-desconocido)
        info "${C_AMARILLO}Firma válida, pero de una clave que no conoces${C_FIN}, huella $huella."
        info "Compárala con quien te dio el pendrive por otro canal. Si coincide, repite con --confiar <nombre>." ;;
      *) info "${C_ROJO}${C_NEGRITA}Firma no válida o ausente.${C_FIN} No puedes saber quién preparó este pendrive." ;;
    esac
    (( danado )) && info "${C_ROJO}${C_NEGRITA}El manifiesto tiene líneas con un formato que no es el suyo.${C_FIN}"
    if (( ${#c_tipo} )); then
      info ""
      info "${C_ROJO}${C_NEGRITA}Cambios desde la firma (${#c_tipo})${C_FIN}"
      for (( i = 1; i <= ${#c_tipo}; i++ )); do info "  ${c_tipo[i]}  $(visible "${c_ruta[i]}")"; done
    else
      info "Ningún fichero ha cambiado desde la firma."
    fi
  fi

  [[ $v == alterado ]] && return $R_PELIGROSO
  [[ $estado == firmante-desconocido ]] && return $R_SOSPECHOSO
  return $R_OK
}

# Orden `inspeccionar`: recorre el volumen sin escribir en él y aplica las reglas comunes.

typeset -gi N_FICHEROS=0 N_CARPETAS=0
typeset -gi LIMITE_PROFUNDIDAD=32 LIMITE_ENTRADAS=100000
typeset -ga PAQUETES_MACOS=(app prefpane kext plugin bundle workflow action scptd)

# Entradas vistas, para que `copiar` y `firmar` reutilicen el recorrido.
typeset -ga E_REL E_TIPO
# Rutas relativas con algún hallazgo peligroso, que `copiar` omite.
typeset -gA RUTA_PELIGROSA

typeset -gA DISPOSITIVO
typeset -ga DISPOSITIVO_INTERFACES
typeset -g AV_MOTOR=ninguno AV_ESTADO=omitido AV_DETALLE=''

anotar_ruta() {
  anotar "$@"
  [[ $1 == peligroso ]] && RUTA_PELIGROSA[$3]=1
  return 0
}

# Condiciones de `find` que podan los artefactos del sistema y los paquetes de macOS, para
# anotarlos una vez sin descender en ellos. Los ficheros ._ no se podan aquí, porque solo son
# artefacto si de verdad son AppleDouble; se deciden por su contenido.
condiciones_poda() {
  local -a c=('(')
  local nombre ext
  for nombre in ${(k)ARTEFACTO}; do c+=(-iname "$nombre" -o); done
  if [[ ${1:-} != sin-paquetes ]]; then
    for ext in $PAQUETES_MACOS; do c+=('(' -type d -iname "*.$ext" ')' -o); done
  fi
  c[-1]=')'
  print -rN -- "${c[@]}"
}

# Deja en REPLY los códigos de los caracteres de la lista que aparecen en el nombre. Sin
# subprocesos, porque se llama con cada entrada del volumen.
caracteres_en() {
  local nombre=$1 ch h; shift
  local -a hallados
  for ch in "$@"; do
    [[ $nombre == *$ch* ]] || continue
    h=$(( [##16] #ch ))
    hallados+=("U+${(l:4::0:)h}")
  done
  REPLY=${(j:, :)hallados}
}

# Reglas que dependen solo del nombre. Anota directamente.
reglas_de_nombre() {
  local rel=$1 nombre=$2 tipo=$3 profundidad=$4
  local ext='' ext2='' base nivel

  if [[ $nombre == *[${(j::)CARS_BIDI}${(j::)CARS_INVISIBLES}${(j::)CARS_PUNTOS}]* ]]; then
    caracteres_en "$nombre" "${CARS_BIDI[@]}"
    [[ -n $REPLY ]] && anotar_ruta peligroso caracter-bidi "$rel" \
      "El nombre lleva caracteres que cambian el sentido del texto ($REPLY) y pueden disfrazar la extensión"
    caracteres_en "$nombre" "${CARS_INVISIBLES[@]}"
    [[ -n $REPLY ]] && anotar_ruta sospechoso caracter-invisible "$rel" \
      "El nombre lleva caracteres invisibles ($REPLY)"
    caracteres_en "$nombre" "${CARS_PUNTOS[@]}"
    [[ -n $REPLY ]] && anotar_ruta peligroso punto-falso "$rel" \
      "El nombre usa un carácter que imita un punto ($REPLY) para fingir una extensión"
  fi

  [[ $nombre == *.* ]] && ext=${(L)nombre:e}
  base=${nombre%.*}
  [[ $nombre == *.* && $base == *.* ]] && ext2=${(L)base:e}

  if [[ $tipo == d ]]; then
    # En un directorio solo cuentan las extensiones de paquete de macOS.
    (( ${PAQUETES_MACOS[(Ie)$ext]} )) || return 0
  fi

  if [[ $tipo == f && ${(L)nombre} == autorun.inf ]]; then
    if (( profundidad == 1 )); then
      anotar_ruta peligroso autorun "$rel" "Fichero de arranque automático en la raíz del pendrive"
    else
      anotar_ruta sospechoso autorun "$rel" "Fichero de arranque automático fuera de la raíz"
    fi
    return 0
  fi

  [[ -n $ext && -n ${EXT_NIVEL[$ext]:-} ]] || return 0
  nivel=${EXT_NIVEL[$ext]}

  # El acceso directo junto a una carpeta oculta se resuelve después, cuando ya se conocen todas.
  [[ $tipo == f && $ext == lnk ]] && { LNK_PENDIENTES+=("$rel"); return 0 }

  if [[ $nombre == *[[:space:]][[:space:]][[:space:]]* ]]; then
    anotar_ruta peligroso extension-camuflada "$rel" \
      "Esconde la extensión .$ext detrás de espacios. ${EXT_MOTIVO[$ext]}"
  elif [[ $nivel == peligroso && -n $ext2 && -n ${EXT_DOC[$ext2]:-} ]]; then
    anotar_ruta peligroso doble-extension "$rel" \
      "Parece un .$ext2 pero es .$ext. ${EXT_MOTIVO[$ext]}"
  else
    if [[ $nivel == peligroso ]]; then
      anotar_ruta peligroso extension-peligrosa "$rel" "${EXT_MOTIVO[$ext]}"
    else
      anotar_ruta "$nivel" extension-sospechosa "$rel" "${EXT_MOTIVO[$ext]}"
    fi
  fi
}

typeset -ga LNK_PENDIENTES
typeset -gA CARPETA_OCULTA

resolver_accesos_directos() {
  local rel padre base
  for rel in $LNK_PENDIENTES; do
    padre=${rel:h}; [[ $rel == */* ]] || padre=.
    base=${${rel:t}%.*}
    if (( ${+CARPETA_OCULTA[${(L)padre}/${(L)base}]} )); then
      anotar_ruta peligroso carpeta-suplantada "$rel" \
        "Acceso directo que se hace pasar por la carpeta «$base», que está oculta al lado"
    else
      anotar_ruta peligroso extension-peligrosa "$rel" "${EXT_MOTIVO[lnk]}"
    fi
  done
}

tiene_macros() {
  local fichero=$1 magia=$2
  case $magia in
    504b0304*) unzip -Z1 "$fichero" 2>/dev/null | grep -qi 'vbaproject\.bin$' ;;
    d0cf11e0a1b11ae1*)
      # En OLE el nombre del flujo va en UTF-16LE; quitando los NUL queda en ASCII.
      head -c 67108864 "$fichero" | LC_ALL=C tr -d '\000' | LC_ALL=C grep -aq '_VBA_PROJECT' ;;
    *) return 1 ;;
  esac
}

reglas_de_contenido() {
  local raiz=$1; shift
  local -a rutas=("$@")
  (( ${#rutas} )) || return 0
  local -a magias
  magias=("${(@f)$(printf '%s\0' "${rutas[@]}" | ayudante magias)}")
  local i rel nombre ext magia hex tipo nivel_ext
  for (( i = 1; i <= ${#rutas}; i++ )); do
    rel=${rutas[i]#$raiz/}
    nombre=${rutas[i]:t}
    ext=''; [[ $nombre == *.* ]] && ext=${(L)nombre:e}
    magia=${magias[i]:-!}
    [[ $magia == [-!] ]] && continue
    nivel_ext=${EXT_NIVEL[$ext]:-}

    for hex tipo in ${(kv)FIRMA}; do
      [[ $magia == ${hex}* ]] || continue
      if [[ $hex == 2321 ]]; then
        [[ -z $ext ]] && anotar_ruta peligroso script-sin-extension "$rel" \
          "Script sin extensión, que macOS ejecuta en Terminal con doble clic"
      elif [[ $nivel_ext != (peligroso|sospechoso) ]]; then
        if [[ -n $ext ]]; then
          anotar_ruta peligroso contenido-ejecutable "$rel" "Tiene extensión .$ext pero es un $tipo"
        else
          anotar_ruta peligroso contenido-ejecutable "$rel" "No tiene extensión y es un $tipo"
        fi
      fi
      break
    done

    if [[ -n $ext && -n ${EXT_OFFICE[$ext]:-} && $nivel_ext != peligroso ]] && tiene_macros "${rutas[i]}" "$magia"; then
      anotar_ruta peligroso macros "$rel" "Documento con macros aunque su extensión no lo diga"
    fi
  done
}

# Aplica las reglas a una entrada del recorrido. Usa las variables locales de `recorrer`.
procesar_entrada() {
  local raiz=$1 p=$2 tipo=$3 rel nombre profundidad padre
  rel=${p#$raiz/}
  nombre=${p:t}
  profundidad=$(( ${#${rel//[^\/]/}} + 1 ))

  if [[ ${(L)nombre} == desktop.ini && $tipo == f ]]; then
    E_REL+=("$rel"); E_TIPO+=(a)
    if desktop_ini_con_clsid "$p"; then
      anotar_ruta sospechoso desktop-ini "$rel" "Personaliza la carpeta con un identificador de clase, que puede lanzar código"
    else
      anotar informativo artefacto-sistema "$rel" "Fichero de sistema de Windows"
    fi
    return 0
  fi

  if es_artefacto "$nombre"; then
    E_REL+=("$rel"); E_TIPO+=(a)
    anotar informativo artefacto-sistema "$rel" "Fichero de sistema que no es tuyo ni de quien te lo presta"
    return 0
  fi

  E_REL+=("$rel"); E_TIPO+=($tipo)

  case $tipo in
    l)
      anotar_ruta sospechoso enlace-simbolico "$rel" "Enlace que apunta a otro sitio. Aduana no lo sigue"
      return 0 ;;
    d)
      (( ++N_CARPETAS ))
      if [[ $nombre == .* || -n ${ocultos[$p]:-} ]]; then
        padre=${rel:h}; [[ $rel == */* ]] || padre=.
        CARPETA_OCULTA[${(L)padre}/${(L)nombre}]=1
        anotar informativo oculto "$rel" "Carpeta oculta"
      fi
      [[ -r $p && -x $p ]] || anotar informativo sin-acceso "$rel" "No tengo permiso para leer esta carpeta, así que no he revisado su contenido"
      (( profundidad > LIMITE_PROFUNDIDAD )) && \
        anotar informativo limite-alcanzado "$rel" "Demasiado profunda, no he revisado lo que hay dentro"
      ;;
    f)
      (( ++N_FICHEROS ))
      [[ $nombre == .* || -n ${ocultos[$p]:-} ]] && anotar informativo oculto "$rel" "Fichero oculto"
      ficheros+=("$p")
      ;;
  esac
  reglas_de_nombre "$rel" "$nombre" "$tipo" "$profundidad"
}

recorrer() {
  local raiz=$1
  local -a poda ficheros
  local -A ocultos
  local p rel tipo
  local -i total=0

  poda=("${(@0)$(condiciones_poda)}")
  poda=(${poda:#})

  while IFS= read -r -d '' p; do ocultos[$p]=1; done < <(
    find -x "$raiz" -mindepth 1 -maxdepth $(( LIMITE_PROFUNDIDAD + 1 )) "${poda[@]}" -prune -o -flags +hidden -print0 2>/dev/null)

  local -a pendientes_ad
  while IFS= read -r -d '' p; do
    (( ++total > LIMITE_ENTRADAS )) && {
      anotar informativo limite-alcanzado . "Hay más de $LIMITE_ENTRADAS entradas y no he revisado el resto"
      break
    }
    if [[ -L $p ]]; then tipo=l
    elif [[ -d $p ]]; then tipo=d
    else tipo=f; fi
    # Un ._algo se decide después, cuando se sepa si empieza por la firma AppleDouble.
    if [[ $tipo == f ]] && es_prefijo_artefacto "${p:t}"; then pendientes_ad+=("$p"); continue; fi
    procesar_entrada "$raiz" "$p" "$tipo"
  done < <(find -x "$raiz" -mindepth 1 -maxdepth $(( LIMITE_PROFUNDIDAD + 1 )) "${poda[@]}" -prune -print0 -o -print0 2>/dev/null)

  # Un ._ que no es AppleDouble es un fichero oculto cualquiera, y así se revisa. Si no, un
  # ._trampa.exe pasaría por basura de macOS.
  if (( ${#pendientes_ad} )); then
    local -a magias_ad
    local i
    magias_ad=("${(@f)$(printf '%s\0' "${pendientes_ad[@]}" | ayudante magias)}")
    for (( i = 1; i <= ${#pendientes_ad}; i++ )); do
      if [[ ${magias_ad[i]:-} == 00051607* ]]; then
        rel=${pendientes_ad[i]#$raiz/}
        E_REL+=("$rel"); E_TIPO+=(a)
        anotar informativo artefacto-sistema "$rel" "Fichero de sistema que no es tuyo ni de quien te lo presta"
      else
        procesar_entrada "$raiz" "${pendientes_ad[i]}" f
      fi
    done
  fi

  resolver_accesos_directos
  reglas_de_contenido "$raiz" "${ficheros[@]}"
}

# ---------------------------------------------------------------------------------------------
# El dispositivo: solo si la ruta es la raíz de un volumen montado que no es interno.

inspeccionar_dispositivo() {
  local raiz=$1
  local -a v
  v=("${(@f)$(diskutil info -plist "$raiz" 2>/dev/null | ayudante plist-campos MountPoint Internal ParentWholeDisk BusProtocol MediaName FilesystemUserVisibleName)}")
  [[ ${v[1]:-} == "$raiz" && ${v[2]:-} == false ]] || return 0
  local disco=${v[3]}
  DISPOSITIVO=(bus "${v[4]}" modelo "${v[5]}" sistemaFicheros "${v[6]}" fabricante '')

  local id contenido punto
  while IFS=$'\t' read -r id contenido punto; do
    [[ -z $id || -n $punto ]] && continue
    [[ $contenido == (EFI|Apple_Boot|Apple_APFS|Apple_APFS_ISC|Apple_APFS_Recovery|Apple_CoreStorage|Microsoft\ Reserved|Apple_partition_map|Apple_Free) ]] && continue
    anotar_ruta sospechoso particion-oculta . "Partición $id ($contenido) sin montar en el mismo pendrive"
  done < <(diskutil list -plist "$disco" 2>/dev/null | ayudante particiones)

  [[ ${v[4]} == USB ]] || return 0
  local clave valor
  while IFS=$'\t' read -r clave valor; do
    case $clave in
      fabricante) DISPOSITIVO[fabricante]=$valor ;;
      modelo) [[ -n $valor ]] && DISPOSITIVO[modelo]=$valor ;;
      interfaz)
        DISPOSITIVO_INTERFACES+=("$valor")
        case $valor in
          3) anotar_ruta peligroso dispositivo-hid . "El pendrive se anuncia también como teclado o dispositivo de entrada" ;;
          2|10|224) anotar_ruta sospechoso dispositivo-red . "El pendrive se anuncia también como tarjeta de red" ;;
        esac ;;
      cd) anotar_ruta sospechoso unidad-cd-virtual . "El pendrive incluye una unidad de CD virtual" ;;
    esac
  done < <(ioreg -a -r -c IOUSBHostDevice 2>/dev/null | ayudante usb "$disco")
  return 0
}

# ---------------------------------------------------------------------------------------------
# Antivirus: ClamAV si está instalado. macOS no ofrece una forma de lanzar XProtect a demanda.

pasar_antivirus() {
  local raiz=$1
  if [[ -n ${OPT[sin-antivirus]:-} ]]; then AV_ESTADO=omitido; return 0; fi
  if ! command -v clamscan >/dev/null; then
    AV_ESTADO=no-disponible AV_DETALLE='ClamAV no está instalado. Con Homebrew, brew install clamav y después freshclam.'
    return 0
  fi
  AV_MOTOR=ClamAV
  local salida linea ruta firma
  local -i rc=0
  salida=$(clamscan -r --no-summary --infected --stdout -- "$raiz" 2>/dev/null) || rc=$?
  case $rc in
    0) AV_ESTADO=limpio ;;
    1)
      AV_ESTADO=detecciones
      for linea in "${(@f)salida}"; do
        [[ $linea == *': '*' FOUND' ]] || continue
        ruta=${linea%: *}; firma=${${linea##*: }% FOUND}
        anotar_ruta peligroso antivirus "${ruta#$raiz/}" "$firma"
      done ;;
    *) AV_ESTADO=error AV_DETALLE="clamscan terminó con el código $rc" ;;
  esac
}

# ---------------------------------------------------------------------------------------------
# VirusTotal, solo por hash. La clave nunca va en la línea de órdenes, donde la vería `ps`.

consultar_virustotal() {
  local raiz=$1
  [[ -n ${OPT[virustotal]:-} ]] || return 0
  [[ -n ${VT_API_KEY:-} ]] || { aviso "falta VT_API_KEY, no consulto VirusTotal."; return 0 }
  local cabecera=$(mktemp -t aduana-vt)
  chmod 600 "$cabecera"
  print -r -- "x-apikey: $VT_API_KEY" > "$cabecera"
  local -a candidatos
  local -A vistos
  local i rel
  for (( i = 1; i <= ${#H_RUTA}; i++ )); do
    rel=${H_RUTA[i]}
    [[ ${H_NIVEL[i]} == (peligroso|sospechoso) && $rel != . && -f $raiz/$rel && ! -L $raiz/$rel && -z ${vistos[$rel]:-} ]] || continue
    vistos[$rel]=1; candidatos+=("$rel")
  done
  (( ${#candidatos} > 20 )) && anotar informativo virustotal . \
    "Hay ${#candidatos} ficheros para consultar y solo reviso 20, por el límite de la API gratuita"
  local -i n=0
  local huella codigo cuerpo maliciosos
  for rel in ${candidatos[1,20]}; do
    (( n++ )) && sleep 15
    huella=$(shasum -a 256 < "$raiz/$rel" | cut -d' ' -f1)
    cuerpo=$(mktemp -t aduana-vt)
    codigo=$(curl -sS -o "$cuerpo" -w '%{http_code}' -H @"$cabecera" "https://www.virustotal.com/api/v3/files/$huella" 2>/dev/null) || codigo=000
    if [[ $codigo == 200 ]]; then
      maliciosos=$(ayudante json-campo data.attributes.last_analysis_stats.malicious < "$cuerpo")
      if (( maliciosos >= 3 )); then
        anotar_ruta peligroso virustotal "$rel" "$maliciosos motores de VirusTotal lo consideran malicioso"
      elif (( maliciosos >= 1 )); then
        anotar_ruta sospechoso virustotal "$rel" "$maliciosos motores de VirusTotal lo consideran malicioso"
      fi
    elif [[ $codigo != 404 ]]; then
      anotar informativo virustotal "$rel" "VirusTotal no ha respondido bien (código $codigo), queda sin consultar"
    fi
    rm -f "$cuerpo"
  done
  rm -f "$cabecera"
}

# ---------------------------------------------------------------------------------------------
# Informes

informe_texto() {
  local raiz=$1 v=$2 nivel i color titulo
  info "${C_NEGRITA}Aduana $ADUANA_VERSION${C_FIN}, inspección de $(visible "$raiz")"
  info "Ficheros revisados, $N_FICHEROS. Carpetas, $N_CARPETAS."
  if (( ${#DISPOSITIVO} )); then
    local -a nombre_disp=(${DISPOSITIVO[fabricante]} ${DISPOSITIVO[modelo]})
    info "Dispositivo, ${${(j: :)nombre_disp}:-sin nombre} por ${DISPOSITIVO[bus]}, con ${DISPOSITIVO[sistemaFicheros]}."
  fi
  local -a orden=("${(@f)$(indices_ordenados)}")
  for nivel in peligroso sospechoso informativo; do
    local -i n=$(contar_nivel $nivel)
    (( n )) || continue
    case $nivel in
      peligroso) color=$C_ROJO titulo=PELIGROSO ;;
      sospechoso) color=$C_AMARILLO titulo=SOSPECHOSO ;;
      *) color=$C_AZUL titulo=INFORMATIVO ;;
    esac
    info ""
    info "${color}${C_NEGRITA}$titulo ($n)${C_FIN}"
    for i in $orden; do
      [[ ${H_NIVEL[i]} == $nivel ]] || continue
      info "  $(visible "${H_RUTA[i]}")"
      info "    ${H_REGLA[i]}: $(visible "${H_DETALLE[i]}")"
    done
  done
  info ""
  case $AV_ESTADO in
    limpio) info "Antivirus, $AV_MOTOR sin detecciones." ;;
    detecciones) info "Antivirus, $AV_MOTOR ha encontrado amenazas." ;;
    no-disponible) info "Antivirus, no disponible. $AV_DETALLE" ;;
    omitido) info "Antivirus, omitido a petición." ;;
    error) info "Antivirus, error. $AV_DETALLE" ;;
  esac
  case $v in
    peligroso) info "${C_ROJO}${C_NEGRITA}Veredicto, peligroso.${C_FIN} No abras nada de este pendrive con doble clic. Copia solo lo que necesites con «aduana copiar»." ;;
    sospechoso) info "${C_AMARILLO}${C_NEGRITA}Veredicto, sospechoso.${C_FIN} Revisa los avisos antes de abrir nada y copia con «aduana copiar»." ;;
    *) info "${C_VERDE}${C_NEGRITA}Veredicto, sin nada peligroso ni sospechoso.${C_FIN} Aun así, copia con «aduana copiar» para conservar la marca de origen." ;;
  esac
}

informe_json() {
  local raiz=$1 v=$2 k primero
  print -rn -- "{\"aduana\":$(json_cadena $ADUANA_VERSION),\"orden\":\"inspeccionar\",\"ruta\":$(json_cadena "$raiz"),"
  print -rn -- "\"fecha\":$(json_cadena "$(fecha_iso)"),\"sistema\":\"macos\","
  print -rn -- "\"resumen\":{\"ficheros\":$N_FICHEROS,\"carpetas\":$N_CARPETAS,\"peligroso\":$(contar_nivel peligroso),"
  print -rn -- "\"sospechoso\":$(contar_nivel sospechoso),\"informativo\":$(contar_nivel informativo)},"
  print -rn -- "\"veredicto\":$(json_cadena $v),\"hallazgos\":$(json_hallazgos),"
  print -rn -- "\"antivirus\":{\"motor\":$(json_cadena $AV_MOTOR),\"estado\":$(json_cadena $AV_ESTADO),\"detalle\":$(json_cadena "$AV_DETALLE")},"
  print -rn -- "\"dispositivo\":"
  if (( ${#DISPOSITIVO} )); then
    print -rn -- "{\"bus\":$(json_cadena "${DISPOSITIVO[bus]}"),\"fabricante\":$(json_cadena "${DISPOSITIVO[fabricante]}"),"
    print -rn -- "\"modelo\":$(json_cadena "${DISPOSITIVO[modelo]}"),\"sistemaFicheros\":$(json_cadena "${DISPOSITIVO[sistemaFicheros]}"),\"interfaces\":["
    primero=1
    for k in $DISPOSITIVO_INTERFACES; do (( primero )) || print -rn -- ','; primero=0; print -rn -- "$(json_cadena "clase $k")"; done
    print -rn -- ']}'
  else
    print -rn -- 'null'
  fi
  print -r -- '}'
}

# Análisis completo sin informe, reutilizado por `copiar`.
analizar() {
  local raiz=$1
  recorrer "$raiz"
  inspeccionar_dispositivo "$raiz"
  pasar_antivirus "$raiz"
}

orden_inspeccionar() {
  local raiz
  requiere_ruta "${ARGS[1]:-}" || return
  raiz=$(absoluta "${ARGS[1]}")
  [[ -d $raiz ]] || { fallo "$(visible "$raiz") no es una carpeta ni un volumen."; return $R_ERROR }
  analizar "$raiz"
  consultar_virustotal "$raiz"
  local v=$(veredicto)
  if [[ -n ${OPT[json]:-} ]]; then informe_json "$raiz" "$v"; else informe_texto "$raiz" "$v"; fi
  codigo_de_veredicto "$v"
}

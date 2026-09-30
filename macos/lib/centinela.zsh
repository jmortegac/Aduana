# Orden `centinela`: vigila durante un rato si aparece un teclado nuevo y, si aparece, bloquea la
# sesión. Se arma justo antes de conectar un pendrive desconocido, que es cuando un BadUSB se
# anunciaría como teclado para escribir órdenes.
#
# Es una mitigación con ventana de carrera. Consulta cada 200 ms y un dispositivo rápido puede
# escribir algo antes del bloqueo. En los Mac con chip de Apple, «Permitir que se conecten
# accesorios» en «Preguntar siempre» es la defensa buena, porque actúa antes de que llegue nada.

# Solo para las pruebas: sustituir la consulta de teclados y el bloqueo.
typeset -g HIDUTIL=${ADUANA_HIDUTIL:-hidutil}
typeset -g BLOQUEO=${ADUANA_BLOQUEO:-}

conocidos_fichero() { print -r -- "$CONFIG_DIR/teclados-conocidos.txt" }

# Una línea por teclado físico, «idRegistro<TAB>fabricante:producto:transporte<TAB>nombre».
listar_teclados() {
  local linea id vid pid transporte nombre
  "$HIDUTIL" list --ndjson --matching keyboard 2>/dev/null | while IFS= read -r linea; do
    [[ $linea == *'"type":"device"'* ]] || continue
    id='' vid=0 pid=0 transporte='' nombre=''
    [[ $linea =~ '"IORegistryEntryID":([0-9]+)' ]] && id=${match[1]}
    [[ $linea =~ '"VendorID":([0-9]+)' ]] && vid=${match[1]}
    [[ $linea =~ '"ProductID":([0-9]+)' ]] && pid=${match[1]}
    [[ $linea =~ '"Transport":"([^"]*)"' ]] && transporte=${match[1]}
    [[ $linea =~ '"Product":"([^"]*)"' ]] && nombre=${match[1]}
    [[ -n $id ]] && print -r -- "$id"$'\t'"$vid:$pid:$transporte"$'\t'"$nombre"
  done
}

bloquear_sesion() {
  if [[ -n $BLOQUEO ]]; then "$BLOQUEO"; return; fi
  [[ $(ayudante bloquear 2>/dev/null) == ok ]] && return 0
  pmset displaysleepnow
}

orden_centinela() {
  local fichero=$(conocidos_fichero) id clave nombre
  local -A iniciales conocidos

  if [[ -n ${OPT[aprender]:-} ]]; then
    mkdir -p "$CONFIG_DIR"
    touch "$fichero"
    local -i nuevos=0
    while IFS=$'\t' read -r id clave nombre; do
      grep -qxF -- "$clave" "$fichero" && continue
      print -r -- "$clave" >> "$fichero"; (( ++nuevos ))
      info "  aprendido, $nombre ($clave)"
    done < <(listar_teclados)
    info "$nuevos teclados nuevos guardados en $(visible "$fichero")."
    return $R_OK
  fi

  local -i durante=${OPT[durante]:-60}
  (( durante > 0 && durante <= 3600 )) || { fallo "--durante va de 1 a 3600 segundos."; return $R_ERROR }
  [[ -f $fichero ]] && while IFS= read -r clave; do [[ -n $clave ]] && conocidos[$clave]=1; done < "$fichero"
  while IFS=$'\t' read -r id clave nombre; do iniciales[$id]=1; done < <(listar_teclados)

  info "Centinela armado durante $durante segundos con ${#iniciales} teclados ya conectados. Conecta ahora el pendrive."
  zmodload zsh/datetime
  local -F fin=$(( EPOCHREALTIME + durante ))
  while (( EPOCHREALTIME < fin )); do
    while IFS=$'\t' read -r id clave nombre; do
      (( ${+iniciales[$id]} || ${+conocidos[$clave]} )) && continue
      bloquear_sesion
      info ""
      info "${C_ROJO}${C_NEGRITA}Ha aparecido un teclado nuevo y he bloqueado la sesión.${C_FIN}"
      info "Dispositivo, ${nombre:-sin nombre} ($clave)."
      info "Si no lo has conectado tú a propósito, desconecta el pendrive antes de volver a entrar."
      return $R_PELIGROSO
    done < <(listar_teclados)
    sleep 0.2
  done
  info "Tiempo cumplido. No ha aparecido ningún teclado nuevo."
  return $R_OK
}

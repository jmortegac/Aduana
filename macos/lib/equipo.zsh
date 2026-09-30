# Órdenes `preparar-equipo`, `restaurar-equipo` y `montar`.

# El dominio se puede cambiar solo para las pruebas, que escriben en un plist temporal en lugar de
# tocar la configuración real del usuario.
typeset -g DOMINIO_DS=${ADUANA_DOMINIO_DS:-com.apple.desktopservices}

estado_equipo() { print -r -- "$CONFIG_DIR/estado-equipo.json" }

bloqueo_inmediato() {
  local estado
  estado=$(sysadminctl -screenLock status 2>&1) || return 1
  [[ $estado == *immediate* ]]
}

orden_preparar_equipo() {
  local estado=$(estado_equipo) previo existia=false
  mkdir -p "$CONFIG_DIR" || { fallo "no puedo crear $CONFIG_DIR."; return $R_ERROR }

  if [[ -e $estado ]]; then
    aviso "este Mac ya estaba preparado. Conservo el estado original para poder restaurarlo."
  else
    local tipo=''
    if previo=$(defaults read "$DOMINIO_DS" DSDontWriteUSBStores 2>/dev/null); then
      existia=true
      tipo=$(defaults read-type "$DOMINIO_DS" DSDontWriteUSBStores 2>/dev/null)
      tipo=${tipo##* }
    else
      previo=''
    fi
    print -r -- "{\"DSDontWriteUSBStores\":{\"existia\":$existia,\"tipo\":$(json_cadena "$tipo"),\"valor\":$(json_cadena "$previo")}}" > "$estado"
  fi

  defaults write "$DOMINIO_DS" DSDontWriteUSBStores -bool true || { fallo "no he podido cambiar la preferencia de Finder."; return $R_ERROR }
  info "Hecho. Finder ya no dejará ficheros .DS_Store en los pendrives."
  [[ -n ${OPT[sin-automontaje]:-} ]] && \
    aviso "macOS no permite desactivar el automontaje sin instalar código propio, así que --sin-automontaje no hace nada aquí. Usa «aduana montar» justo después de conectar el pendrive."

  info ""
  info "Dos ajustes que Aduana no puede cambiar por ti y que merecen la pena:"
  info ""
  info "  1. En Ajustes del Sistema, Privacidad y seguridad, pon «Permitir que se conecten accesorios»"
  info "     en «Preguntar siempre». En los Mac con chip de Apple, así ningún dispositivo USB nuevo"
  info "     funciona hasta que lo apruebes, tampoco un pendrive que finge ser un teclado."
  if ! bloqueo_inmediato; then
    info ""
    info "  2. En Ajustes del Sistema, Pantalla de bloqueo, haz que pida la contraseña inmediatamente."
    info "     Si «aduana centinela» no pudiera bloquear la sesión, apagaría la pantalla, y con el"
    info "     ajuste actual eso no la bloquea al momento."
  fi
  return $R_OK
}

orden_restaurar_equipo() {
  local estado=$(estado_equipo) existia tipo valor
  [[ -e $estado ]] || { info "Este Mac no estaba preparado con Aduana, no hay nada que restaurar."; return $R_OK }
  existia=$(ayudante json-campo DSDontWriteUSBStores.existia < "$estado")
  tipo=$(ayudante json-campo DSDontWriteUSBStores.tipo < "$estado")
  valor=$(ayudante json-campo DSDontWriteUSBStores.valor < "$estado")
  if [[ $existia == true ]]; then
    case $tipo in
      boolean) [[ $valor == 1 ]] && valor=true || valor=false
               defaults write "$DOMINIO_DS" DSDontWriteUSBStores -bool "$valor" ;;
      integer) defaults write "$DOMINIO_DS" DSDontWriteUSBStores -int "$valor" ;;
      *) defaults write "$DOMINIO_DS" DSDontWriteUSBStores -string "$valor" ;;
    esac
  else
    defaults delete "$DOMINIO_DS" DSDontWriteUSBStores 2>/dev/null
  fi
  rm -f "$estado"
  info "Hecho. La preferencia de Finder vuelve a estar como antes de preparar el equipo."
  return $R_OK
}

# ---------------------------------------------------------------------------------------------

normalizar_disco() { print -r -- ${${1#/dev/}#r} }

listar_discos_externos() {
  local -a discos
  discos=("${(@f)$(diskutil list -plist external physical 2>/dev/null | ayudante discos-enteros)}")
  discos=(${discos:#})
  if (( ! ${#discos} )); then
    info "No veo ningún disco externo físico conectado."
    return $R_OK
  fi
  info "Discos externos conectados:"
  local d
  local -a v
  for d in $discos; do
    v=("${(@f)$(diskutil info -plist "$d" 2>/dev/null | ayudante plist-campos MediaName TotalSize BusProtocol)}")
    info "  $d  ${v[1]:-sin nombre}, $(( ${v[2]:-0} / 1000000000 )) GB por ${v[3]:-bus desconocido}"
  done
  info ""
  info "Para montarlo en solo lectura, «aduana montar diskN»."
}

orden_montar() {
  [[ -n ${ARGS[1]:-} ]] || { listar_discos_externos; return }
  local disco=$(normalizar_disco "${ARGS[1]}")
  local -a v
  v=("${(@f)$(diskutil info -plist "$disco" 2>/dev/null | ayudante plist-campos Internal WholeDisk)}")
  [[ ${v[1]:-} == false ]] || { fallo "$disco no existe o es un disco interno. Aduana solo monta discos externos."; return $R_ERROR }
  [[ ${v[2]:-} == true ]] || { fallo "indica el disco entero, como disk4, no una partición."; return $R_ERROR }

  local id contenido punto nuevo
  local -i montados=0
  while IFS=$'\t' read -r id contenido punto; do
    [[ -z $id ]] && continue
    [[ $contenido == (EFI|Apple_Boot|Apple_APFS|Apple_APFS_ISC|Apple_APFS_Recovery|Microsoft\ Reserved|Apple_partition_map|Apple_Free) ]] && continue
    [[ -n $punto ]] && diskutil unmount "$id" >/dev/null 2>&1
    if diskutil mount readOnly "$id" >/dev/null 2>&1; then
      nuevo=$(diskutil info -plist "$id" 2>/dev/null | ayudante plist-campos MountPoint)
      info "  $id montado en solo lectura en $(visible "$nuevo")"
      (( ++montados ))
    else
      aviso "no he podido montar $id ($contenido)."
    fi
  done < <(diskutil list -plist "$disco" 2>/dev/null | ayudante particiones)

  (( montados )) || { fallo "no he montado ninguna partición de $disco."; return $R_ERROR }
  info ""
  info "Ahora, «aduana inspeccionar <punto de montaje>»."
  return $R_OK
}

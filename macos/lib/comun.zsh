# Utilidades comunes de Aduana para macOS: mensajes, argumentos, reglas, JSON y hallazgos.

typeset -g ADUANA_VERSION=0.3.0
typeset -g AYUDANTE="$ADUANA_RAIZ/macos/lib/ayudante.js"
typeset -g REGLAS="$ADUANA_RAIZ/reglas/reglas.json"
typeset -g CONFIG_DIR="${ADUANA_ESTADO:-$HOME/Library/Application Support/Aduana}"

# Códigos de retorno del contrato común con Windows.
typeset -gri R_OK=0 R_SOSPECHOSO=1 R_PELIGROSO=2 R_ERROR=3

# ---------------------------------------------------------------------------------------------
# Mensajes

typeset -g C_ROJO='' C_AMARILLO='' C_AZUL='' C_VERDE='' C_NEGRITA='' C_FIN=''
colores_si_consola() {
  if [[ -t 1 && -z ${NO_COLOR:-} && -z ${OPT[json]:-} ]]; then
    C_ROJO=$'\e[31m' C_AMARILLO=$'\e[33m' C_AZUL=$'\e[36m' C_VERDE=$'\e[32m'
    C_NEGRITA=$'\e[1m' C_FIN=$'\e[0m'
  fi
}

info()  { print -r -- "$*" }
aviso() { print -ru2 -- "${C_AMARILLO}Aviso${C_FIN}, $*" }
fallo() { print -ru2 -- "${C_ROJO}Error${C_FIN}, $*"; return $R_ERROR }

ayudante() { osascript -l JavaScript "$AYUDANTE" "$@" }

# ---------------------------------------------------------------------------------------------
# Argumentos: posicionales en ARGS, opciones en OPT. Las opciones con valor son las de la lista.

typeset -ga ARGS
typeset -gA OPT
typeset -ga OPCIONES_CON_VALOR=(durante nombre limite clave salida firmantes confiar)
typeset -ga OPCIONES_BOOLEANAS=(json virustotal sin-antivirus incluir-peligrosos desinfectar
  borrado-completo si solo-informe aprender sin-automontaje)

parsear_argumentos() {
  ARGS=() OPT=()
  local a nombre
  while (( $# )); do
    a=$1; shift
    if [[ $a == --* ]]; then
      nombre=${a#--}
      if (( ${OPCIONES_CON_VALOR[(Ie)$nombre]} )); then
        (( $# )) || { fallo "a la opción --$nombre le falta el valor."; return $R_ERROR }
        OPT[$nombre]=$1; shift
      elif (( ${OPCIONES_BOOLEANAS[(Ie)$nombre]} )); then
        OPT[$nombre]=1
      else
        fallo "no conozco la opción --$nombre. Prueba con «aduana ayuda»."; return $R_ERROR
      fi
    else
      ARGS+=("$a")
    fi
  done
}

# ---------------------------------------------------------------------------------------------
# Reglas compartidas con Windows, cargadas desde reglas.json.

typeset -gA EXT_NIVEL EXT_MOTIVO EXT_DOC EXT_OFFICE ARTEFACTO FIRMA
typeset -ga PREFIJOS_ARTEFACTO CARS_BIDI CARS_INVISIBLES CARS_PUNTOS

cargar_reglas() {
  local linea tipo a b c
  local -a partes
  while IFS= read -r linea; do
    partes=("${(@ps:\t:)linea}")
    tipo=${partes[1]} a=${partes[2]:-} b=${partes[3]:-} c=${partes[4]:-}
    case $tipo in
      E) EXT_NIVEL[$a]=$b; EXT_MOTIVO[$a]=$c ;;
      D) EXT_DOC[$a]=1 ;;
      O) EXT_OFFICE[$a]=1 ;;
      A) ARTEFACTO[${(L)a}]=1 ;;
      P) PREFIJOS_ARTEFACTO+=("$a") ;;
      B) CARS_BIDI+=("${(#):-0x$a}") ;;
      I) CARS_INVISIBLES+=("${(#):-0x$a}") ;;
      F) CARS_PUNTOS+=("${(#):-0x$a}") ;;
      S) FIRMA[$a]=$b ;;
    esac
  done < <(ayudante reglas "$REGLAS")
  (( ${#EXT_NIVEL} )) || { fallo "no he podido cargar $REGLAS."; return $R_ERROR }
}

es_artefacto() { (( ${+ARTEFACTO[${(L)1}]} )) }

# Los ._ de macOS guardan atributos en volúmenes que no son APFS. Solo cuentan como artefacto si
# su contenido empieza por la firma AppleDouble, 00 05 16 07; eso lo decide quien llama.
es_prefijo_artefacto() {
  local p
  for p in $PREFIJOS_ARTEFACTO; do [[ $1 == ${p}* ]] && return 0; done
  return 1
}

desktop_ini_con_clsid() {
  LC_ALL=C grep -aqi clsid "$1" 2>/dev/null && return 0
  LC_ALL=C tr -d '\000' < "$1" 2>/dev/null | LC_ALL=C grep -aqi clsid
}

# ---------------------------------------------------------------------------------------------
# Texto seguro. Un U+202E en un nombre da la vuelta a la línea entera de la terminal, así que
# los caracteres de control, de dirección, invisibles y los puntos falsos se enseñan como ⟨U+XXXX⟩.

codigo_hex() { printf '%04X' "'$1" }

es_caracter_peligroso() {
  local ch=$1
  [[ $ch == [[:cntrl:]] ]] && return 0
  (( ${CARS_BIDI[(Ie)$ch]} || ${CARS_INVISIBLES[(Ie)$ch]} || ${CARS_PUNTOS[(Ie)$ch]} ))
}

visible() {
  local s=$1 salida='' ch i
  for (( i = 1; i <= ${#s}; i++ )); do
    ch=${s[i]}
    if es_caracter_peligroso "$ch"; then salida+="⟨U+$(codigo_hex "$ch")⟩"; else salida+=$ch; fi
  done
  print -rn -- "$salida"
}

json_cadena() {
  local s=$1 salida='' ch i
  for (( i = 1; i <= ${#s}; i++ )); do
    ch=${s[i]}
    case $ch in
      \\) salida+='\\' ;;
      \") salida+='\"' ;;
      $'\n') salida+='\n' ;;
      $'\r') salida+='\r' ;;
      $'\t') salida+='\t' ;;
      *)
        if es_caracter_peligroso "$ch"; then salida+="\\u${(L)$(codigo_hex "$ch")}"
        else salida+=$ch; fi ;;
    esac
  done
  print -rn -- "\"$salida\""
}

fecha_iso() { date -u +%Y-%m-%dT%H:%M:%SZ }

# ---------------------------------------------------------------------------------------------
# Hallazgos, en cuatro listas paralelas.

typeset -ga H_NIVEL H_REGLA H_RUTA H_DETALLE

anotar() { H_NIVEL+=("$1"); H_REGLA+=("$2"); H_RUTA+=("$3"); H_DETALLE+=("$4") }

contar_nivel() { print -r -- ${#${(M)H_NIVEL:#$1}} }

veredicto() {
  if (( $(contar_nivel peligroso) )); then print peligroso
  elif (( $(contar_nivel sospechoso) )); then print sospechoso
  else print limpio; fi
}

codigo_de_veredicto() {
  case $1 in peligroso) return $R_PELIGROSO ;; sospechoso) return $R_SOSPECHOSO ;; *) return $R_OK ;; esac
}

# Índices de los hallazgos ordenados por nivel y después por ruta, en orden de bytes.
indices_ordenados() {
  local i peso
  for (( i = 1; i <= ${#H_NIVEL}; i++ )); do
    case ${H_NIVEL[i]} in peligroso) peso=1 ;; sospechoso) peso=2 ;; *) peso=3 ;; esac
    printf '%s\t%s\t%s\0' "$peso" "${H_RUTA[i]}" "$i"
  done | LC_ALL=C sort -z -t $'\t' -k1,1n -k2,2 | while IFS= read -r -d '' linea; do
    print -r -- "${linea##*$'\t'}"
  done
}

json_hallazgos() {
  local i primero=1
  print -rn -- '['
  for i in $(indices_ordenados); do
    (( primero )) || print -rn -- ','
    primero=0
    print -rn -- "{\"nivel\":$(json_cadena "${H_NIVEL[i]}"),\"regla\":$(json_cadena "${H_REGLA[i]}"),"
    print -rn -- "\"ruta\":$(json_cadena "${H_RUTA[i]}"),\"detalle\":$(json_cadena "${H_DETALLE[i]}")}"
  done
  print -rn -- ']'
}

# Ruta absoluta sin depender de que exista del todo.
absoluta() { print -r -- ${1:A} }

requiere_ruta() {
  [[ -n ${1:-} ]] || { fallo "falta la ruta. Prueba con «aduana ayuda»."; return $R_ERROR }
  [[ -e $1 ]] || { fallo "no existe $1."; return $R_ERROR }
}

#!/usr/bin/env bash
# Ejecuta las pruebas de la parte de Windows en un contenedor Linux con PowerShell 7.
# El repositorio se monta en solo lectura y el contenedor corre sin red y sin privilegios.
set -euo pipefail

raiz="$(cd "$(dirname "$0")/.." && pwd)"
imagen="aduana-pruebas-windows:local"

docker build --tag "$imagen" --file "$raiz/pruebas/docker/Dockerfile" "$raiz/pruebas/docker"

docker run --rm \
  --network none \
  --read-only \
  --tmpfs /tmp:rw,exec,size=512m \
  --tmpfs /home/aduana:rw,size=64m,uid=10001,gid=10001 \
  --cap-drop ALL \
  --security-opt no-new-privileges:true \
  --volume "$raiz:/repo:ro" \
  "$imagen" "$@"

# syntax=docker/dockerfile:1
#
# Arnés de pruebas de la parte de Windows de Aduana sobre Linux. PowerShell 7 no es el 5.1 de
# Windows, así que esto prueba la sintaxis, la compatibilidad declarada con 5.1 (PSScriptAnalyzer)
# y toda la lógica pura. Lo que toca Windows de verdad va detrás de Sistema.ps1 y aquí se mockea.
#
# Todo lo externo va fijado y verificado. Para subir una versión:
#   PowerShell   hash de la release en https://github.com/PowerShell/PowerShell/releases/download/vX.Y.Z/hashes.sha256
#   Pester, PSSA descargar https://www.powershellgallery.com/api/v2/package/<Nombre>/<versión> y
#                calcular `sha256sum`; comprobar además que su SHA-512 en base64 coincide con el
#                PackageHash que publica la galería en .../api/v2/Packages(Id='<Nombre>',Version='<versión>')

ARG DEBIAN_IMAGE=debian:trixie-slim@sha256:a99cfc517144bc59b1978475ec53b46ecabec7e43635402ee5b77cc54cd1b20a

FROM ${DEBIAN_IMAGE} AS descarga
ARG TARGETARCH
ARG PWSH_VERSION=7.6.6
ARG PWSH_SHA256_ARM64=924829e54c983648f6f1419a2dc7f9433c861b2fb5bd57736ff096c24f133729
ARG PWSH_SHA256_X64=ddbc4a2d113bbd46d283cfedcbcd117a70caefd7673f41f2b4e0000badf103bc
ARG PESTER_VERSION=5.9.1
ARG PESTER_SHA256=8dd4060fc3bc895f05bd655e4ab82abe346de54a4e6415dfb727cc8378672b69
ARG PSSA_VERSION=1.25.0
ARG PSSA_SHA256=14e634c828eb98efb9f40b2918ba90f139ed5eccdf663a2a747736d996995d60

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl unzip \
 && rm -rf /var/lib/apt/lists/*

RUN set -eu; \
    case "$TARGETARCH" in \
      arm64) arq=arm64; hash="$PWSH_SHA256_ARM64" ;; \
      amd64) arq=x64; hash="$PWSH_SHA256_X64" ;; \
      *) echo "Arquitectura sin soporte: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/pwsh.tar.gz "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-${arq}.tar.gz"; \
    echo "${hash}  /tmp/pwsh.tar.gz" | sha256sum -c -; \
    mkdir -p /opt/pwsh; \
    tar -xzf /tmp/pwsh.tar.gz -C /opt/pwsh; \
    chmod +x /opt/pwsh/pwsh

# Un nupkg es un zip. Se descomprime en la estructura que espera PowerShell,
# <ruta de módulos>/<Nombre>/<versión>/, y se quitan los metadatos de NuGet.
RUN set -eu; \
    modulo() { \
      nombre="$1"; version="$2"; hash="$3"; \
      curl -fsSL -o "/tmp/$nombre.nupkg" "https://www.powershellgallery.com/api/v2/package/$nombre/$version"; \
      echo "${hash}  /tmp/$nombre.nupkg" | sha256sum -c -; \
      mkdir -p "/opt/modulos/$nombre/$version"; \
      unzip -q "/tmp/$nombre.nupkg" -d "/opt/modulos/$nombre/$version"; \
      rm -rf "/opt/modulos/$nombre/$version/_rels" "/opt/modulos/$nombre/$version/package" \
             "/opt/modulos/$nombre/$version/[Content_Types].xml" "/opt/modulos/$nombre/$version/$nombre.nuspec"; \
    }; \
    modulo Pester "$PESTER_VERSION" "$PESTER_SHA256"; \
    modulo PSScriptAnalyzer "$PSSA_VERSION" "$PSSA_SHA256"

FROM ${DEBIAN_IMAGE}
# libicu para que .NET tenga normalización Unicode completa (las pruebas de NFC la necesitan) y
# openssh-client para probar de verdad la firma y la verificación del manifiesto con ssh-keygen.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libicu76 openssh-client \
 && rm -rf /var/lib/apt/lists/*
COPY --from=descarga /opt/pwsh /opt/pwsh
COPY --from=descarga /opt/modulos /opt/modulos
RUN ln -s /opt/pwsh/pwsh /usr/local/bin/pwsh \
 && useradd --create-home --uid 10001 aduana
ENV PSModulePath=/opt/modulos \
    POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    DOTNET_CLI_TELEMETRY_OPTOUT=1
USER aduana
WORKDIR /repo
ENTRYPOINT ["pwsh", "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "/repo/pruebas/docker/ejecutar.ps1"]

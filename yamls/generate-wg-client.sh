#!/usr/bin/env bash
#
# generate-wg-client.sh -- envsubst wrapper minimo (mismo espiritu que generate-wiki-vm.sh: sin
# validacion propia, lo llama lab-azure.sh despues de ya haber validado todo). Renderiza
# yamls/templates/wg-client.conf.tpl -> yamls/generated/wg-clients/<name>.conf.
#
# Variables esperadas ya exportadas por el llamador: PEER_NAME, CLIENT_PRIVKEY,
# CLIENT_TUNNEL_IP, CLIENT_DNS, SERVER_PUBKEY, GATEWAY_PUBLIC_IP, CLIENT_ALLOWED_IPS.
#
# Uso: PEER_NAME=team3 CLIENT_PRIVKEY=... ... ./generate-wg-client.sh

set -euo pipefail

: "${PEER_NAME:?Falta exportar PEER_NAME}"
: "${CLIENT_PRIVKEY:?Falta exportar CLIENT_PRIVKEY}"
: "${CLIENT_TUNNEL_IP:?Falta exportar CLIENT_TUNNEL_IP}"
: "${CLIENT_DNS:?Falta exportar CLIENT_DNS}"
: "${SERVER_PUBKEY:?Falta exportar SERVER_PUBKEY}"
: "${GATEWAY_PUBLIC_IP:?Falta exportar GATEWAY_PUBLIC_IP}"
: "${CLIENT_ALLOWED_IPS:?Falta exportar CLIENT_ALLOWED_IPS}"

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] falta 'envsubst' (paquete gettext-base)."; exit 1; }

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${WORKDIR}/generated/wg-clients"
mkdir -p "$OUTDIR"

VARS='${PEER_NAME} ${CLIENT_PRIVKEY} ${CLIENT_TUNNEL_IP} ${CLIENT_DNS} ${SERVER_PUBKEY} ${GATEWAY_PUBLIC_IP} ${CLIENT_ALLOWED_IPS}'

out="${OUTDIR}/${PEER_NAME}.conf"
envsubst "$VARS" < "${WORKDIR}/templates/wg-client.conf.tpl" > "$out"
chmod 600 "$out"
echo "generado: $out"

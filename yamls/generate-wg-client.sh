#!/usr/bin/env bash
#
# generate-wg-client.sh -- envsubst wrapper minimo (mismo espiritu que generate-wiki-vm.sh: sin
# validacion propia, lo llama lab-azure.sh despues de ya haber validado todo). Renderiza
# yamls/templates/wg-client.conf.tpl -> yamls/generated/wg-clients/<name>.conf, y
# yamls/templates/wg-client-readme.md.tpl -> yamls/generated/wg-clients/<name>-README.md (el
# entregable del participante -- ver docs/plans/internal-dns.md "Qué se le entrega al participante").
#
# Variables esperadas ya exportadas por el llamador: PEER_NAME, CLIENT_PRIVKEY,
# CLIENT_TUNNEL_IP, CLIENT_DNS, SERVER_PUBKEY, GATEWAY_PUBLIC_IP, CLIENT_ALLOWED_IPS, LAB_DOMAIN.
#
# Uso: PEER_NAME=team3 CLIENT_PRIVKEY=... ... LAB_DOMAIN=sabanacorp.internal ./generate-wg-client.sh

set -euo pipefail

: "${PEER_NAME:?Falta exportar PEER_NAME}"
: "${CLIENT_PRIVKEY:?Falta exportar CLIENT_PRIVKEY}"
: "${CLIENT_TUNNEL_IP:?Falta exportar CLIENT_TUNNEL_IP}"
: "${CLIENT_DNS:?Falta exportar CLIENT_DNS}"
: "${SERVER_PUBKEY:?Falta exportar SERVER_PUBKEY}"
: "${GATEWAY_PUBLIC_IP:?Falta exportar GATEWAY_PUBLIC_IP}"
: "${CLIENT_ALLOWED_IPS:?Falta exportar CLIENT_ALLOWED_IPS}"
: "${LAB_DOMAIN:?Falta exportar LAB_DOMAIN}"

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] falta 'envsubst' (paquete gettext-base)."; exit 1; }

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${WORKDIR}/generated/wg-clients"
mkdir -p "$OUTDIR"

VARS='${PEER_NAME} ${CLIENT_PRIVKEY} ${CLIENT_TUNNEL_IP} ${CLIENT_DNS} ${SERVER_PUBKEY} ${GATEWAY_PUBLIC_IP} ${CLIENT_ALLOWED_IPS}'

out="${OUTDIR}/${PEER_NAME}.conf"
envsubst "$VARS" < "${WORKDIR}/templates/wg-client.conf.tpl" > "$out"
chmod 600 "$out"
echo "generado: $out"

# Tabla de servicios del propio equipo -- solo si PEER_NAME es team<N> (el peer 'admin' no tiene
# equipo propio, se queda solo con la tabla de la DMZ del README).
TEAM_SERVICES_BLOCK=""
if [[ "$PEER_NAME" =~ ^team([0-9]+)$ ]]; then
  team="${BASH_REMATCH[1]}"
  TEAM_SERVICES_BLOCK="$(cat <<EOF
| Servicio (tu equipo) | Nombre |
|---|---|
| Helpdesk (Reto 1: XSS/LFI) | \`webapp.team${team}.${LAB_DOMAIN}\` (alias: \`helpdesk.team${team}.${LAB_DOMAIN}\`) |
| Base de datos | \`database.team${team}.${LAB_DOMAIN}\` (alias: \`db.team${team}.${LAB_DOMAIN}\`) |
| Servidor Linux (Reto 3: pivote) | \`linux-server.team${team}.${LAB_DOMAIN}\` (alias: \`pivot.team${team}.${LAB_DOMAIN}\`) |
| XSS-bot | \`xss-bot.team${team}.${LAB_DOMAIN}\` (alias: \`bot.team${team}.${LAB_DOMAIN}\`) |
EOF
)"
fi
export TEAM_SERVICES_BLOCK LAB_DOMAIN

readme_out="${OUTDIR}/${PEER_NAME}-README.md"
envsubst '${PEER_NAME} ${LAB_DOMAIN} ${TEAM_SERVICES_BLOCK}' \
  < "${WORKDIR}/templates/wg-client-readme.md.tpl" > "$readme_out"
echo "generado: $readme_out"

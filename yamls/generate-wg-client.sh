#!/usr/bin/env bash
#
# generate-wg-client.sh -- minimal envsubst wrapper (same spirit as generate-wiki-vm.sh: no
# own validation, called by lab-azure.sh after it has already validated everything). Renders
# yamls/templates/wg-client.conf.tpl -> yamls/generated/wg-clients/<name>.conf, and
# yamls/templates/wg-client-readme.md.tpl -> yamls/generated/wg-clients/<name>-README.md (the
# participant deliverable -- see docs/plans/internal-dns.md "What is delivered to the participant").
#
# Variables expected to already be exported by the caller: PEER_NAME, CLIENT_PRIVKEY,
# CLIENT_TUNNEL_IP, CLIENT_DNS, SERVER_PUBKEY, GATEWAY_PUBLIC_IP, CLIENT_ALLOWED_IPS, LAB_DOMAIN.
#
# Usage: PEER_NAME=team3 CLIENT_PRIVKEY=... ... LAB_DOMAIN=sabanacorp.internal ./generate-wg-client.sh

set -euo pipefail

: "${PEER_NAME:?Missing exported PEER_NAME}"
: "${CLIENT_PRIVKEY:?Missing exported CLIENT_PRIVKEY}"
: "${CLIENT_TUNNEL_IP:?Missing exported CLIENT_TUNNEL_IP}"
: "${CLIENT_DNS:?Missing exported CLIENT_DNS}"
: "${SERVER_PUBKEY:?Missing exported SERVER_PUBKEY}"
: "${GATEWAY_PUBLIC_IP:?Missing exported GATEWAY_PUBLIC_IP}"
: "${CLIENT_ALLOWED_IPS:?Missing exported CLIENT_ALLOWED_IPS}"
: "${LAB_DOMAIN:?Missing exported LAB_DOMAIN}"

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] missing 'envsubst' (package gettext-base)."; exit 1; }

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${WORKDIR}/generated/wg-clients"
mkdir -p "$OUTDIR"

VARS='${PEER_NAME} ${CLIENT_PRIVKEY} ${CLIENT_TUNNEL_IP} ${CLIENT_DNS} ${SERVER_PUBKEY} ${GATEWAY_PUBLIC_IP} ${CLIENT_ALLOWED_IPS}'

out="${OUTDIR}/${PEER_NAME}.conf"
envsubst "$VARS" < "${WORKDIR}/templates/wg-client.conf.tpl" > "$out"
chmod 600 "$out"
echo "generated: $out"

# Service table for the team itself -- only if PEER_NAME is team<N> (the 'admin' peer does not have
# its own team, it only gets the DMZ table from the README).
TEAM_SERVICES_BLOCK=""
if [[ "$PEER_NAME" =~ ^team([0-9]+)$ ]]; then
  team="${BASH_REMATCH[1]}"
  TEAM_SERVICES_BLOCK="$(cat <<EOF
| Service (your team) | Name |
|---|---|
| Helpdesk (Challenge 1: XSS/LFI) | \`webapp.team${team}.${LAB_DOMAIN}\` (alias: \`helpdesk.team${team}.${LAB_DOMAIN}\`) |
| Database | \`database.team${team}.${LAB_DOMAIN}\` (alias: \`db.team${team}.${LAB_DOMAIN}\`) |
| Linux Server (Challenge 3: pivot) | \`linux-server.team${team}.${LAB_DOMAIN}\` (alias: \`pivot.team${team}.${LAB_DOMAIN}\`) |
| XSS-bot | \`xss-bot.team${team}.${LAB_DOMAIN}\` (alias: \`bot.team${team}.${LAB_DOMAIN}\`) |
EOF
)"
fi
export TEAM_SERVICES_BLOCK LAB_DOMAIN

readme_out="${OUTDIR}/${PEER_NAME}-README.md"
envsubst '${PEER_NAME} ${LAB_DOMAIN} ${TEAM_SERVICES_BLOCK}' \
  < "${WORKDIR}/templates/wg-client-readme.md.tpl" > "$readme_out"
echo "generated: $readme_out"

# Single-file bundle of nmap-sabana-corp (docs/plans/nmap-sabana-corp.md, "Distribution to
# participant", layer 2) -- does not depend on PEER_NAME, regenerates the same way on every call because there
# is no team state to cache and the cost is a concatenation of a few KB (<100ms).
NMAP_TOOL_DIR="${WORKDIR}/../tools/nmap-sabana-corp"
if [[ -f "${NMAP_TOOL_DIR}/scripts/build-bundle.mjs" ]]; then
  if command -v node >/dev/null 2>&1; then
    node "${NMAP_TOOL_DIR}/scripts/build-bundle.mjs" "${OUTDIR}/nmap-sabana-corp.mjs"
  else
    echo "[WARN] 'node' not available -- nmap-sabana-corp.mjs not generated (participant can still use 'npm i -g nmap-sabana-corp')." >&2
  fi
else
  echo "[WARN] tools/nmap-sabana-corp not found -- nmap-sabana-corp.mjs not generated." >&2
fi

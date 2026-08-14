#!/usr/bin/env bash
#
# generate-dmz.sh — generates ACI YAML for the shared DMZ from
# yamls/templates/dmz-*.yaml.tpl (filesrv, parking, 11 decoys).
#
# The wiki is not here: it runs on vm-wiki with docker-compose (see generate-wiki-vm.sh and
# docs/plans/wiki-on-vm.md), not as an ACI container.
#
# Unlike team-*.yaml.tpl, these do not depend on a team number -- they are a single
# shared deployment for all teams.
#
# Usage:
#   export DOCKERHUB_USER="..."
#   export DOCKERHUB_TOKEN="..."
#   ./generate-dmz.sh
#
# Writes yamls/generated/dmz-*.yaml (13 files).

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-ctf-semana-ingenieria-test}"
VNET="${VNET:-vnet-ctf-lab}"
LAB_DOMAIN="${LAB_DOMAIN:-sabanacorp.internal}"
LAB_DNS_SERVER="${LAB_DNS_SERVER:-}"
: "${DOCKERHUB_USER:?Missing exported DOCKERHUB_USER}"
: "${DOCKERHUB_TOKEN:?Missing exported DOCKERHUB_TOKEN}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id --output tsv)}"

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] missing 'envsubst' (package gettext-base)."; exit 1; }

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${WORKDIR}/templates"
OUTDIR="${WORKDIR}/generated"
mkdir -p "$OUTDIR"

export RESOURCE_GROUP VNET DOCKERHUB_USER DOCKERHUB_TOKEN SUBSCRIPTION_ID LAB_DOMAIN LAB_DNS_SERVER
VARS='${RESOURCE_GROUP} ${VNET} ${DOCKERHUB_USER} ${DOCKERHUB_TOKEN} ${SUBSCRIPTION_ID} ${LAB_DOMAIN} ${LAB_DNS_SERVER}'

for tpl in "${TEMPLATES}"/dmz-*.yaml.tpl; do
  base="$(basename "$tpl" .yaml.tpl)"
  out="${OUTDIR}/${base}.yaml"
  envsubst "$VARS" < "$tpl" > "$out"
  # LAB_DNS_SERVER empty == lab without gateway -- see the same note in generate-team.sh.
  if [[ -z "$LAB_DNS_SERVER" ]]; then
    sed -i '/DNSCONFIG-BEGIN/,/DNSCONFIG-END/d' "$out"
  fi
  echo "generated: $out"
done

#!/usr/bin/env bash
#
# generate-dmz.sh — genera los YAML de ACI de la DMZ compartida a partir de
# yamls/templates/dmz-*.yaml.tpl (filesrv, parking, 11 decoys).
#
# El wiki no esta aqui: corre en vm-wiki con docker-compose (ver generate-wiki-vm.sh y
# docs/plans/wiki-on-vm.md), no como contenedor ACI.
#
# A diferencia de team-*.yaml.tpl, estos no dependen de un numero de equipo -- son un solo
# despliegue compartido por todos los equipos.
#
# Uso:
#   export DOCKERHUB_USER="..."
#   export DOCKERHUB_TOKEN="..."
#   ./generate-dmz.sh
#
# Escribe yamls/generated/dmz-*.yaml (13 archivos).

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-ctf-semana-ingenieria-test}"
VNET="${VNET:-vnet-ctf-lab}"
LAB_DOMAIN="${LAB_DOMAIN:-sabanacorp.internal}"
LAB_DNS_SERVER="${LAB_DNS_SERVER:-}"
: "${DOCKERHUB_USER:?Falta exportar DOCKERHUB_USER}"
: "${DOCKERHUB_TOKEN:?Falta exportar DOCKERHUB_TOKEN}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id --output tsv)}"

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] falta 'envsubst' (paquete gettext-base)."; exit 1; }

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
  # LAB_DNS_SERVER vacio == lab sin gateway -- ver la misma nota en generate-team.sh.
  if [[ -z "$LAB_DNS_SERVER" ]]; then
    sed -i '/DNSCONFIG-BEGIN/,/DNSCONFIG-END/d' "$out"
  fi
  echo "generado: $out"
done

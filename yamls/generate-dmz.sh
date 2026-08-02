#!/usr/bin/env bash
#
# generate-dmz.sh — genera los YAML de ACI de la DMZ compartida a partir de
# yamls/templates/dmz-*.yaml.tpl (filesrv, wiki-db, wiki, parking, 11 decoys).
#
# A diferencia de team-*.yaml.tpl, estos no dependen de un numero de equipo -- son un solo
# despliegue compartido por todos los equipos.
#
# Uso:
#   export DOCKERHUB_USER="..."
#   export DOCKERHUB_TOKEN="..."
#   ./generate-dmz.sh
#
# Escribe yamls/generated/dmz-*.yaml (14 archivos).

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-ctf-semana-ingenieria-test}"
VNET="${VNET:-vnet-ctf-lab}"
: "${DOCKERHUB_USER:?Falta exportar DOCKERHUB_USER}"
: "${DOCKERHUB_TOKEN:?Falta exportar DOCKERHUB_TOKEN}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id --output tsv)}"

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] falta 'envsubst' (paquete gettext-base)."; exit 1; }

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${WORKDIR}/templates"
OUTDIR="${WORKDIR}/generated"
mkdir -p "$OUTDIR"

export RESOURCE_GROUP VNET DOCKERHUB_USER DOCKERHUB_TOKEN SUBSCRIPTION_ID
VARS='${RESOURCE_GROUP} ${VNET} ${DOCKERHUB_USER} ${DOCKERHUB_TOKEN} ${SUBSCRIPTION_ID}'

for tpl in "${TEMPLATES}"/dmz-*.yaml.tpl; do
  base="$(basename "$tpl" .yaml.tpl)"
  out="${OUTDIR}/${base}.yaml"
  envsubst "$VARS" < "$tpl" > "$out"
  echo "generado: $out"
done

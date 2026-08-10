#!/usr/bin/env bash
#
# generate-wiki-vm.sh — genera el docker-compose.yml para la VM del wiki (snet-dmz-vm) a partir
# de yamls/templates/wiki-vm-compose.yml.tpl.
#
# Validado end-to-end 2026-08-08 -- ver docs/plans/wiki-on-vm.md. El compose generado se desplego
# en vm-wiki y BookStack arranco correctamente contra su MariaDB.
#
# Uso:
#   ./generate-wiki-vm.sh
#
# Escribe yamls/generated/wiki-vm-docker-compose.yml
#
# Los secretos del wiki son literales aca abajo, no vienen de .env.secrets -- igual que el resto
# de la DMZ compartida (ver yamls/README.md "Pendiente / gaps conocidos"). Este es hoy el unico
# lugar donde viven: las plantillas de ACI dmz-wiki*.yaml.tpl, que los duplicaban, ya no existen.

set -euo pipefail

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] falta 'envsubst' (paquete gettext-base)."; exit 1; }

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${WORKDIR}/templates"
OUTDIR="${WORKDIR}/generated"
mkdir -p "$OUTDIR"

export WIKI_MYSQL_ROOT_PASSWORD="rootpass"
export WIKI_DB_PASSWORD="bookstackpass"
export WIKI_APP_KEY="base64:LrA+08seUQX+vAK+resD+m79e2Gj68/pGXCr1kqm75M="
export LAB_DOMAIN="${LAB_DOMAIN:-sabanacorp.internal}"

VARS='${WIKI_MYSQL_ROOT_PASSWORD} ${WIKI_DB_PASSWORD} ${WIKI_APP_KEY} ${LAB_DOMAIN}'

in="${TEMPLATES}/wiki-vm-compose.yml.tpl"
out="${OUTDIR}/wiki-vm-docker-compose.yml"
envsubst "$VARS" < "$in" > "$out"
echo "generado: $out"

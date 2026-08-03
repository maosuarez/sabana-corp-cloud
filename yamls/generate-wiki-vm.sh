#!/usr/bin/env bash
#
# generate-wiki-vm.sh — genera el docker-compose.yml para la VM del wiki (snet-dmz-vm) a partir
# de yamls/templates/wiki-vm-compose.yml.tpl.
#
# NO PROBADO -- ver docs/plans/wiki-on-vm.md. Escrito sin poder correrlo (cuenta sin cuota de VM
# al momento de escribir esto). Revisar contra la realidad antes de confiar en que genera un
# compose valido.
#
# Uso:
#   ./generate-wiki-vm.sh
#
# Escribe yamls/generated/wiki-vm-docker-compose.yml
#
# Mismos valores de secretos que hoy usan dmz-wiki.yaml.tpl / dmz-wiki-db.yaml.tpl (literales, no
# vienen de .env.secrets -- igual que el resto de la DMZ compartida, ver yamls/README.md
# "Pendiente / gaps conocidos"). Si se cambia aca, hay que cambiar tambien alla o quedan
# desincronizados mientras convivan ambos despliegues (ACI viejo vs VM nueva).

set -euo pipefail

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] falta 'envsubst' (paquete gettext-base)."; exit 1; }

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${WORKDIR}/templates"
OUTDIR="${WORKDIR}/generated"
mkdir -p "$OUTDIR"

export WIKI_MYSQL_ROOT_PASSWORD="rootpass"
export WIKI_DB_PASSWORD="bookstackpass"
export WIKI_APP_KEY="base64:LrA+08seUQX+vAK+resD+m79e2Gj68/pGXCr1kqm75M="

VARS='${WIKI_MYSQL_ROOT_PASSWORD} ${WIKI_DB_PASSWORD} ${WIKI_APP_KEY}'

in="${TEMPLATES}/wiki-vm-compose.yml.tpl"
out="${OUTDIR}/wiki-vm-docker-compose.yml"
envsubst "$VARS" < "$in" > "$out"
echo "generado: $out"

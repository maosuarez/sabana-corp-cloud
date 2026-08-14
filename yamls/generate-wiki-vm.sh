#!/usr/bin/env bash
#
# generate-wiki-vm.sh — generates the docker-compose.yml for the wiki VM (snet-dmz-vm) from
# yamls/templates/wiki-vm-compose.yml.tpl.
#
# Validated end-to-end 2026-08-08 -- see docs/plans/wiki-on-vm.md. The generated compose was deployed
# on vm-wiki and BookStack started correctly against its MariaDB.
#
# Usage:
#   ./generate-wiki-vm.sh
#
# Writes yamls/generated/wiki-vm-docker-compose.yml
#
# Wiki secrets are literals below, they do not come from .env.secrets -- same as the rest
# of the shared DMZ (see yamls/README.md "Pending / known gaps"). This is currently the only
# place where they live: the ACI templates dmz-wiki*.yaml.tpl, which duplicated them, no longer exist.

set -euo pipefail

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] missing 'envsubst' (package gettext-base)."; exit 1; }

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
echo "generated: $out"

#!/usr/bin/env bash
#
# generate-team.sh — genera los 4 YAML de ACI de un equipo a partir de yamls/templates/team-*.yaml.tpl
#
# Uso:
#   export DOCKERHUB_USER="..."
#   export DOCKERHUB_TOKEN="..."
#   cp .env.secrets.example .env.secrets   # solo la primera vez, y editar valores reales
#   ./generate-team.sh <N>
#
# Escribe yamls/generated/team<N>-{database,webapp,linux-server,xss-bot}.yaml
#
# Los secretos/flags (FLAG_*, PIVOT_SSH_PASSWORD, BOT_SECRET, MYSQL_ROOT_PASSWORD,
# DB_APP_PASSWORD, JWT_SIGNING_SECRET) se leen de yamls/.env.secrets y son los MISMOS para todos
# los equipos -- generate-team.sh 1 y generate-team.sh 2 producen el mismo valor de flag, solo
# cambia el nombre del container group y la subred. Asi el mismo set de flags que cargas una vez
# en CTFd sirve para cualquier equipo.
#
# <DATABASE_IP> y <WEBAPP_IP> quedan sin resolver a proposito: dependen de la IP que Azure asigne
# al desplegar database/webapp, y eso no se sabe hasta despues del deploy. Ver yamls/README.md.
#
# Requiere que exista la subred snet-team<N> (10.60.<N>.0/24) delegada a
# Microsoft.ContainerInstance/containerGroups -- este script no la crea.

set -euo pipefail

TEAM="${1:?Uso: $0 <numero_de_equipo>}"

case "$TEAM" in
  ''|*[!0-9]*) echo "[ERROR] <numero_de_equipo> debe ser un entero (ej. 1, 2, 20)."; exit 1 ;;
esac

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-ctf-semana-ingenieria-test}"
VNET="${VNET:-vnet-ctf-lab}"
: "${DOCKERHUB_USER:?Falta exportar DOCKERHUB_USER}"
: "${DOCKERHUB_TOKEN:?Falta exportar DOCKERHUB_TOKEN}"
SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-$(az account show --query id --output tsv)}"

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] falta 'envsubst' (paquete gettext-base)."; exit 1; }

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${WORKDIR}/templates"
OUTDIR="${WORKDIR}/generated"
SECRETS_FILE="${WORKDIR}/.env.secrets"
mkdir -p "$OUTDIR"

[[ -f "$SECRETS_FILE" ]] || { echo "[ERROR] falta ${SECRETS_FILE} (copia .env.secrets.example y rellena valores reales)."; exit 1; }

SECRET_VARS=(FLAG_WEBAPP_XSS FLAG_WEBAPP_LFI FLAG_DATABASE FLAG_LINUXSERVER_ROOT FLAG_LINUXSERVER_PROC \
             PIVOT_SSH_PASSWORD BOT_SECRET MYSQL_ROOT_PASSWORD DB_APP_PASSWORD JWT_SIGNING_SECRET)

set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

for v in "${SECRET_VARS[@]}"; do
  [[ -n "${!v:-}" ]] || { echo "[ERROR] falta ${v} en ${SECRETS_FILE}."; exit 1; }
done

export TEAM RESOURCE_GROUP VNET DOCKERHUB_USER DOCKERHUB_TOKEN SUBSCRIPTION_ID
# Lista explicita: envsubst solo reemplaza estas variables y deja intactos otros ${...}/<...>
# (p.ej. <DATABASE_IP>, que no usa sintaxis ${} y nunca corre riesgo de ser tocado).
VARS='${TEAM} ${RESOURCE_GROUP} ${VNET} ${DOCKERHUB_USER} ${DOCKERHUB_TOKEN} ${SUBSCRIPTION_ID}'
for v in "${SECRET_VARS[@]}"; do
  VARS="${VARS} \${${v}}"
done

for svc in database webapp linux-server xss-bot; do
  in="${TEMPLATES}/team-${svc}.yaml.tpl"
  out="${OUTDIR}/team${TEAM}-${svc}.yaml"
  envsubst "$VARS" < "$in" > "$out"
  echo "generado: $out"
done

echo
echo "Pendiente manual: rellenar <DATABASE_IP> en team${TEAM}-webapp.yaml y <WEBAPP_IP> en"
echo "team${TEAM}-xss-bot.yaml despues de desplegar database/webapp (ver yamls/README.md)."

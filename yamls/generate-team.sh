#!/usr/bin/env bash
#
# generate-team.sh — generates 4 ACI YAMLs for a team from yamls/templates/team-*.yaml.tpl
#
# Usage:
#   export DOCKERHUB_USER="..."
#   export DOCKERHUB_TOKEN="..."
#   cp .env.secrets.example .env.secrets   # only the first time, and edit actual values
#   ./generate-team.sh <N>
#
# Writes yamls/generated/team<N>-{database,webapp,linux-server,xss-bot}.yaml
#
# Secrets/flags (FLAG_*, PIVOT_SSH_PASSWORD, BOT_SECRET, MYSQL_ROOT_PASSWORD,
# DB_APP_PASSWORD, JWT_SIGNING_SECRET) are read from yamls/.env.secrets and are the SAME for all
# teams -- generate-team.sh 1 and generate-team.sh 2 produce the same flag value, only
# the container group name and subnet change. So the same set of flags that you load once
# in CTFd serves for any team.
#
# <DATABASE_IP> and <WEBAPP_IP> are deliberately left unresolved: they depend on the IP that Azure assigns
# when deploying database/webapp, and that is not known until after the deploy. See yamls/README.md.
# This does NOT change with internal DNS (see docs/plans/internal-dns.md): challenge env vars
# stay on IP deliberately, DNS is only for human names/navigation.
#
# Requires that subnet snet-team<N> (10.60.<N>.0/24) delegated to
# Microsoft.ContainerInstance/containerGroups already exists -- this script does not create it.

set -euo pipefail

TEAM="${1:?Usage: $0 <team_number>}"

case "$TEAM" in
  ''|*[!0-9]*) echo "[ERROR] <team_number> must be an integer (e.g. 1, 2, 20)."; exit 1 ;;
esac

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
SECRETS_FILE="${WORKDIR}/.env.secrets"
mkdir -p "$OUTDIR"

[[ -f "$SECRETS_FILE" ]] || { echo "[ERROR] missing ${SECRETS_FILE} (copy .env.secrets.example and fill in actual values)."; exit 1; }

SECRET_VARS=(FLAG_WEBAPP_XSS FLAG_WEBAPP_LFI FLAG_DATABASE FLAG_LINUXSERVER_ROOT FLAG_LINUXSERVER_PROC \
             PIVOT_SSH_PASSWORD BOT_SECRET MYSQL_ROOT_PASSWORD DB_APP_PASSWORD JWT_SIGNING_SECRET)

set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

for v in "${SECRET_VARS[@]}"; do
  [[ -n "${!v:-}" ]] || { echo "[ERROR] missing ${v} in ${SECRETS_FILE}."; exit 1; }
done

export TEAM RESOURCE_GROUP VNET DOCKERHUB_USER DOCKERHUB_TOKEN SUBSCRIPTION_ID LAB_DOMAIN LAB_DNS_SERVER
# Explicit list: envsubst only replaces these variables and leaves other ${...}/<...> untouched
# (e.g. <DATABASE_IP>, which does not use ${} syntax and is never at risk of being touched).
VARS='${TEAM} ${RESOURCE_GROUP} ${VNET} ${DOCKERHUB_USER} ${DOCKERHUB_TOKEN} ${SUBSCRIPTION_ID} ${LAB_DOMAIN} ${LAB_DNS_SERVER}'
for v in "${SECRET_VARS[@]}"; do
  VARS="${VARS} \${${v}}"
done

for svc in database webapp linux-server xss-bot; do
  in="${TEMPLATES}/team-${svc}.yaml.tpl"
  out="${OUTDIR}/team${TEAM}-${svc}.yaml"
  envsubst "$VARS" < "$in" > "$out"
  # LAB_DNS_SERVER empty == lab without gateway (./lab-azure.sh test, or gateway not deployed
  # yet): envsubst does not know conditionals, so the block with DNSCONFIG-BEGIN/END sentinels
  # is the simplest way to leave the YAML without dnsConfig in that case.
  if [[ -z "$LAB_DNS_SERVER" ]]; then
    sed -i '/DNSCONFIG-BEGIN/,/DNSCONFIG-END/d' "$out"
  fi
  echo "generated: $out"
done

echo
echo "Manual pending: fill in <DATABASE_IP> in team${TEAM}-webapp.yaml and <WEBAPP_IP> in"
echo "team${TEAM}-xss-bot.yaml after deploying database/webapp (see yamls/README.md)."

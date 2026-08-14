#!/usr/bin/env bash
#
# generate-ctfd-vm.sh — generates the complete bundle for the CTFd VM (snet-dmz-vm):
#
#   generated/ctfd/docker-compose.yml   -- from templates/ctfd-compose.yml.tpl
#   generated/ctfd/conf/nginx/http.conf -- copied from ctfd-vm/conf/nginx/http.conf (vendored here,
#                                           static, does not depend on sabana-corp-CTFd)
#   generated/ctfd/seed/{seed_challenges.py,requirements.txt,challenges.yml,seed_setup.py}
#                                        -- copied FRESH on each run from $CTFD_REPO_DIR
#                                           (default ../sabana-corp-CTFd, sibling repo) -- NOT
#                                           vendored in this repo: that manifest/scripts live in
#                                           sabana-corp-CTFd, it is their source of truth (see
#                                           docs/plans/ctfd-deployment.md)
#   generated/ctfd/seed/flags.env       -- only the FLAG_* from yamls/.env.secrets (not the rest of
#                                           secrets), so that seed_challenges.py can read it with
#                                           --env-file inside the VM
#
# create_ctfd_vm() in lab-azure.sh uploads this entire bundle (tar+base64) to vm-ctfd and runs, in
# order: seed_setup.py (completes /setup, 'docker compose exec ctfd python3 -') and then
# seed_challenges.py (against http://localhost, on the VM host) -- neither depends on the
# operator being connected to the VPN.
#
# Unlike generate-wiki-vm.sh (literal secrets -- the DMZ is a single shared deployment),
# CTFd secrets DO come from yamls/.env.secrets (CTFD_* block), including CTFD_PRESET_ADMIN_TOKEN
# -- CTFd accepts it as an Access Token of an admin it creates on the fly (see
# CTFd/utils/security/auth.py:lookup_user_token), so it closes the gap of "generate token
# manually" that the original plan had. CTFD_EVENT_NAME/CTFD_EVENT_DESCRIPTION/CTFD_TEAM_SIZE
# feed seed_setup.py to complete the /setup wizard without manual intervention either.
#
# Usage:
#   export DOCKERHUB_USER="..."
#   cp yamls/.env.secrets.example yamls/.env.secrets   # only the first time, edit actual values
#   ./generate-ctfd-vm.sh
#
# Optional environment variables:
#   CTFD_REPO_DIR   path to sabana-corp-CTFd repo (default: sibling of this repo)
#   CTFD_IMAGE_TAG, CTFD_PORT, CTFD_HTTP_PORT, CTFD_WORKERS  -- see defaults below

set -euo pipefail

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] missing 'envsubst' (package gettext-base)."; exit 1; }

: "${DOCKERHUB_USER:?Missing exported DOCKERHUB_USER}"

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${WORKDIR}/templates"
SRC="${WORKDIR}/ctfd-vm"
OUTDIR="${WORKDIR}/generated/ctfd"
SECRETS_FILE="${WORKDIR}/.env.secrets"
CTFD_REPO_DIR="${CTFD_REPO_DIR:-$(cd "${WORKDIR}/../.." && pwd)/sabana-corp-CTFd}"

[[ -f "$SECRETS_FILE" ]] || { echo "[ERROR] missing ${SECRETS_FILE} (copy .env.secrets.example and fill in actual values)."; exit 1; }
[[ -d "$CTFD_REPO_DIR" ]] || { echo "[ERROR] ${CTFD_REPO_DIR} not found (sabana-corp-CTFd repo). Export CTFD_REPO_DIR if it is at a different path."; exit 1; }

# CTFD_PRESET_ADMIN_* are no longer optional: automatic seeding (create_ctfd_vm() in
# lab-azure.sh) depends on CTFd being able to create the preset admin on the fly via PRESET_ADMIN_TOKEN,
# which in turn requires valid name/email/password (see generate_preset_admin() in CTFd).
SECRET_VARS=(CTFD_SECRET_KEY CTFD_DB_NAME CTFD_DB_USER CTFD_DB_PASSWORD CTFD_DB_ROOT_PASSWORD \
             CTFD_PRESET_ADMIN_NAME CTFD_PRESET_ADMIN_EMAIL CTFD_PRESET_ADMIN_PASSWORD \
             CTFD_PRESET_ADMIN_TOKEN)

set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

for v in "${SECRET_VARS[@]}"; do
  [[ -n "${!v:-}" ]] || { echo "[ERROR] missing ${v} in ${SECRETS_FILE}."; exit 1; }
done

: "${CTFD_EVENT_NAME:?Missing CTFD_EVENT_NAME in ${SECRETS_FILE} (event name, used by seed_setup.py to complete /setup)}"
CTFD_EVENT_DESCRIPTION="${CTFD_EVENT_DESCRIPTION:-}"
CTFD_TEAM_SIZE="${CTFD_TEAM_SIZE:-}"

# Non-secrets with safe defaults if not exported.
IMAGE_TAG="${CTFD_IMAGE_TAG:-latest}"
CTFD_PORT="${CTFD_PORT:-8000}"
HTTP_PORT="${CTFD_HTTP_PORT:-80}"
WORKERS="${CTFD_WORKERS:-2}"
LAB_DOMAIN="${LAB_DOMAIN:-sabanacorp.internal}"
# "localhost" must be included: seed_challenges.py and the health check of
# create_ctfd_vm() hit http://localhost INSIDE vm-ctfd (via nginx), and CTFd rejects with
# 500 (Werkzeug SecurityError: "Host is not trusted") any Host header outside this list --
# see CTFd/__init__.py:create_url_adapter. Found in the first real run 2026-08-11.
#
# CTFD_VM_IP (optional, injected by create_ctfd_vm() with the actual private IP of vm-ctfd) also
# goes in the list: WireGuard split-DNS is NOT reliable on Linux clients (see
# docs/plans/internal-dns.md), so a Linux operator often ends up navigating by IP directly --
# without this, that access also returns 500. Found in the same validation session.
TRUSTED_HOSTS="ctfd.dmz.${LAB_DOMAIN},localhost${CTFD_VM_IP:+,${CTFD_VM_IP}}"
DOCKERHUB_IMAGE="${DOCKERHUB_USER}/sabana-corp-ctfd"

mkdir -p "${OUTDIR}/conf/nginx" "${OUTDIR}/seed"

export DOCKERHUB_IMAGE IMAGE_TAG CTFD_PORT HTTP_PORT WORKERS TRUSTED_HOSTS \
       CTFD_SECRET_KEY CTFD_DB_NAME CTFD_DB_USER CTFD_DB_PASSWORD CTFD_DB_ROOT_PASSWORD \
       CTFD_PRESET_ADMIN_NAME CTFD_PRESET_ADMIN_EMAIL CTFD_PRESET_ADMIN_PASSWORD CTFD_PRESET_ADMIN_TOKEN \
       CTFD_EVENT_NAME CTFD_EVENT_DESCRIPTION CTFD_TEAM_SIZE

VARS='${DOCKERHUB_IMAGE} ${IMAGE_TAG} ${CTFD_PORT} ${HTTP_PORT} ${WORKERS} ${TRUSTED_HOSTS}'
VARS="${VARS} \${CTFD_SECRET_KEY} \${CTFD_DB_NAME} \${CTFD_DB_USER} \${CTFD_DB_PASSWORD} \${CTFD_DB_ROOT_PASSWORD}"
VARS="${VARS} \${CTFD_PRESET_ADMIN_NAME} \${CTFD_PRESET_ADMIN_EMAIL} \${CTFD_PRESET_ADMIN_PASSWORD} \${CTFD_PRESET_ADMIN_TOKEN}"
VARS="${VARS} \${CTFD_EVENT_NAME} \${CTFD_EVENT_DESCRIPTION} \${CTFD_TEAM_SIZE}"

envsubst "$VARS" < "${TEMPLATES}/ctfd-compose.yml.tpl" > "${OUTDIR}/docker-compose.yml"
cp "${SRC}/conf/nginx/http.conf" "${OUTDIR}/conf/nginx/http.conf"

SEED_SCRIPT="${CTFD_REPO_DIR}/scripts/seed_challenges.py"
SEED_REQS="${CTFD_REPO_DIR}/scripts/requirements.txt"
SEED_MANIFEST="${CTFD_REPO_DIR}/challenges/challenges.yml"
SETUP_SCRIPT="${CTFD_REPO_DIR}/scripts/seed_setup.py"
for f in "$SEED_SCRIPT" "$SEED_REQS" "$SEED_MANIFEST" "$SETUP_SCRIPT"; do
  [[ -f "$f" ]] || { echo "[ERROR] missing ${f} in sabana-corp-CTFd repo (${CTFD_REPO_DIR})."; exit 1; }
done
cp "$SEED_SCRIPT" "$SEED_REQS" "$SEED_MANIFEST" "$SETUP_SCRIPT" "${OUTDIR}/seed/"

grep -E '^FLAG_[A-Z0-9_]+=' "$SECRETS_FILE" > "${OUTDIR}/seed/flags.env" || true
[[ -s "${OUTDIR}/seed/flags.env" ]] || { echo "[ERROR] no FLAG_* variables found in ${SECRETS_FILE}."; exit 1; }

echo "generated: ${OUTDIR}"

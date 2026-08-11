#!/usr/bin/env bash
#
# generate-ctfd-vm.sh — genera el bundle completo para la VM de CTFd (snet-dmz-vm):
#
#   generated/ctfd/docker-compose.yml   -- desde templates/ctfd-compose.yml.tpl
#   generated/ctfd/conf/nginx/http.conf -- copiado de ctfd-vm/conf/nginx/http.conf (vendored aqui,
#                                           estatico, no depende de sabana-corp-CTFd)
#   generated/ctfd/seed/{seed_challenges.py,requirements.txt,challenges.yml,seed_setup.py}
#                                        -- copiados FRESCOS en cada corrida desde $CTFD_REPO_DIR
#                                           (por defecto ../sabana-corp-CTFd, sibling repo) -- NO
#                                           vendored en este repo: ese manifiesto/scripts viven en
#                                           sabana-corp-CTFd, es su fuente de verdad (ver
#                                           docs/plans/ctfd-deployment.md)
#   generated/ctfd/seed/flags.env       -- solo las FLAG_* de yamls/.env.secrets (no el resto de
#                                           secretos), para que seed_challenges.py las lea con
#                                           --env-file dentro de la VM
#
# create_ctfd_vm() en lab-azure.sh sube este bundle entero (tar+base64) a vm-ctfd y corre, en
# orden: seed_setup.py (completa /setup, 'docker compose exec ctfd python3 -') y luego
# seed_challenges.py (contra http://localhost, en el host de la VM) -- ninguno depende de que el
# operador esté conectado a la VPN.
#
# A diferencia de generate-wiki-vm.sh (secretos literales -- la DMZ es un solo despliegue
# compartido), los secretos de CTFd SÍ vienen de yamls/.env.secrets (bloque CTFD_*), incluyendo
# CTFD_PRESET_ADMIN_TOKEN -- CTFd lo acepta como Access Token de un admin que crea al vuelo (ver
# CTFd/utils/security/auth.py:lookup_user_token), así que cierra el hueco de "generar el token a
# mano" que tenía el plan original. CTFD_EVENT_NAME/CTFD_EVENT_DESCRIPTION/CTFD_TEAM_SIZE
# alimentan seed_setup.py para completar el wizard de /setup sin intervención manual tampoco.
#
# Uso:
#   export DOCKERHUB_USER="..."
#   cp yamls/.env.secrets.example yamls/.env.secrets   # solo la primera vez, editar valores reales
#   ./generate-ctfd-vm.sh
#
# Variables de entorno opcionales:
#   CTFD_REPO_DIR   ruta al repo sabana-corp-CTFd (default: sibling de este repo)
#   CTFD_IMAGE_TAG, CTFD_PORT, CTFD_HTTP_PORT, CTFD_WORKERS  -- ver defaults abajo

set -euo pipefail

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] falta 'envsubst' (paquete gettext-base)."; exit 1; }

: "${DOCKERHUB_USER:?Falta exportar DOCKERHUB_USER}"

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${WORKDIR}/templates"
SRC="${WORKDIR}/ctfd-vm"
OUTDIR="${WORKDIR}/generated/ctfd"
SECRETS_FILE="${WORKDIR}/.env.secrets"
CTFD_REPO_DIR="${CTFD_REPO_DIR:-$(cd "${WORKDIR}/../.." && pwd)/sabana-corp-CTFd}"

[[ -f "$SECRETS_FILE" ]] || { echo "[ERROR] falta ${SECRETS_FILE} (copia .env.secrets.example y rellena valores reales)."; exit 1; }
[[ -d "$CTFD_REPO_DIR" ]] || { echo "[ERROR] no se encontró ${CTFD_REPO_DIR} (repo sabana-corp-CTFd). Exporta CTFD_REPO_DIR si está en otra ruta."; exit 1; }

# CTFD_PRESET_ADMIN_* dejaron de ser opcionales: el seed automatico (create_ctfd_vm() en
# lab-azure.sh) depende de que CTFd pueda crear el admin preset al vuelo via PRESET_ADMIN_TOKEN,
# lo que a su vez requiere nombre/email/password validos (ver generate_preset_admin() en CTFd).
SECRET_VARS=(CTFD_SECRET_KEY CTFD_DB_NAME CTFD_DB_USER CTFD_DB_PASSWORD CTFD_DB_ROOT_PASSWORD \
             CTFD_PRESET_ADMIN_NAME CTFD_PRESET_ADMIN_EMAIL CTFD_PRESET_ADMIN_PASSWORD \
             CTFD_PRESET_ADMIN_TOKEN)

set -a
# shellcheck disable=SC1090
source "$SECRETS_FILE"
set +a

for v in "${SECRET_VARS[@]}"; do
  [[ -n "${!v:-}" ]] || { echo "[ERROR] falta ${v} en ${SECRETS_FILE}."; exit 1; }
done

: "${CTFD_EVENT_NAME:?Falta CTFD_EVENT_NAME en ${SECRETS_FILE} (nombre del evento, lo usa seed_setup.py para completar /setup)}"
CTFD_EVENT_DESCRIPTION="${CTFD_EVENT_DESCRIPTION:-}"
CTFD_TEAM_SIZE="${CTFD_TEAM_SIZE:-}"

# No-secretos con default seguro si no se exportan.
IMAGE_TAG="${CTFD_IMAGE_TAG:-latest}"
CTFD_PORT="${CTFD_PORT:-8000}"
HTTP_PORT="${CTFD_HTTP_PORT:-80}"
WORKERS="${CTFD_WORKERS:-2}"
LAB_DOMAIN="${LAB_DOMAIN:-sabanacorp.internal}"
# "localhost" tiene que estar incluido: seed_challenges.py y el chequeo de salud de
# create_ctfd_vm() pegan contra http://localhost DENTRO de vm-ctfd (via nginx), y CTFd rechaza con
# 500 (Werkzeug SecurityError: "Host is not trusted") cualquier Host header fuera de esta lista --
# ver CTFd/__init__.py:create_url_adapter. Encontrado en la primera corrida real 2026-08-11.
#
# CTFD_VM_IP (opcional, la inyecta create_ctfd_vm() con la IP privada real de vm-ctfd) también
# entra a la lista: el split-DNS de WireGuard NO es confiable en clientes Linux (ver
# docs/plans/internal-dns.md), así que un operador en Linux termina navegando por IP directo con
# frecuencia -- sin esto, ese acceso también tira 500. Encontrado en la misma sesión de validación.
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
  [[ -f "$f" ]] || { echo "[ERROR] falta ${f} en el repo sabana-corp-CTFd (${CTFD_REPO_DIR})."; exit 1; }
done
cp "$SEED_SCRIPT" "$SEED_REQS" "$SEED_MANIFEST" "$SETUP_SCRIPT" "${OUTDIR}/seed/"

grep -E '^FLAG_[A-Z0-9_]+=' "$SECRETS_FILE" > "${OUTDIR}/seed/flags.env" || true
[[ -s "${OUTDIR}/seed/flags.env" ]] || { echo "[ERROR] no se encontraron variables FLAG_* en ${SECRETS_FILE}."; exit 1; }

echo "generado: ${OUTDIR}"

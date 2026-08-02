#!/usr/bin/env bash
#
# lab-azure.sh — Entorno de prueba Azure para el CTF Semana de Ingeniería
#
# Resumen de lo que se hizo y validó (2026-08-01/02, sesión de prueba):
#   1. az CLI instalado y verificado (Ubuntu/WSL)
#   2. az login -> suscripción "Azure for Students" (tenant Universidad de la Sabana)
#   3. Resource Group creado
#   4. VNet creada con 4 subredes: wg-gateway, dmz-shared, team1, mgmt
#   5. snet-team1 delegada a Microsoft.ContainerInstance/containerGroups
#   6. Provider Microsoft.ContainerInstance registrado en la suscripción
#   7. Container group "team1-edificio" (database + webapp + linux-server + xss-bot)
#      desplegado en snet-team1 con IP privada 10.60.1.4 -- FUNCIONÓ, los 4 contenedores
#      quedaron en estado Running (verificado con az container show / az container logs).
#
# Desde entonces (ver yamls/): el despliegue monolítico de arriba se reemplazó por
# 1-YAML-por-contenedor (yamls/templates/*.tpl + yamls/generate-{team,dmz}.sh), para que cada
# contenedor reciba su propia IP privada. Este script ahora orquesta esos YAML en vez de generar
# uno combinado.
#
# Uso:
#   export DOCKERHUB_USER="tu_usuario"
#   export DOCKERHUB_TOKEN="tu_access_token"   # Docker Hub -> Account Settings -> Security -> New Access Token
#   cp yamls/.env.secrets.example yamls/.env.secrets   # solo la primera vez, editar valores reales
#
#   ./lab-azure.sh up            # crea RG + VNet + subredes base + delega snet-dmz-shared
#   ./lab-azure.sh deploy-dmz    # despliega los 15 contenedores compartidos de la DMZ
#   ./lab-azure.sh add-team 1    # crea snet-team1 y despliega sus 4 contenedores
#   ./lab-azure.sh add-team 2    # idem para team2 (repetir por cada equipo)
#   ./lab-azure.sh status        # lista todos los container groups del RG (nombre/estado/IP)
#   ./lab-azure.sh down          # destruye TODO (borra el resource group completo)
#
# Diseño: todo vive dentro de un solo Resource Group, así que "down" es un solo comando.

set -euo pipefail

# ---------------------------------------------------------------------------
# Variables (ajusta aquí si cambias nombres)
# ---------------------------------------------------------------------------
RG="rg-ctf-semana-ingenieria-test"
LOCATION="eastus2"
VNET="vnet-ctf-lab"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAMLS_DIR="${WORKDIR}/yamls"
SUBSCRIPTION_ID=""

# ---------------------------------------------------------------------------
# Funciones auxiliares
# ---------------------------------------------------------------------------

require_dockerhub_env() {
  : "${DOCKERHUB_USER:?Falta exportar DOCKERHUB_USER}"
  : "${DOCKERHUB_TOKEN:?Falta exportar DOCKERHUB_TOKEN}"
}

get_subscription_id() {
  if [[ -z "$SUBSCRIPTION_ID" ]]; then
    SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
  fi
  echo "$SUBSCRIPTION_ID"
}

# Despliega un container group desde un YAML y devuelve su IP privada por stdout.
# Los echo de progreso van al llamador, no aquí, para no contaminar la captura por $(...).
deploy_container() {
  local file="$1"
  az container create --resource-group "$RG" --file "$file" --query ipAddress.ip --output tsv
}

# ---------------------------------------------------------------------------
# Funciones — infraestructura base
# ---------------------------------------------------------------------------

check_prereqs() {
  echo "== Verificando az CLI y sesión =="
  az version >/dev/null || { echo "az CLI no instalado. Ver: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"; exit 1; }
  az account show >/dev/null 2>&1 || { echo "No hay sesión activa. Corre: az login"; exit 1; }
  az account show --output table
}

create_resource_group() {
  echo "== Paso 1/4: Resource Group =="
  az group create --name "$RG" --location "$LOCATION" --output table
}

create_vnet() {
  echo "== Paso 2/4: VNet + subredes base =="
  az network vnet create \
    --resource-group "$RG" \
    --name "$VNET" \
    --location "$LOCATION" \
    --address-prefixes 10.0.0.0/8 \
    --subnet-name snet-wg-gateway \
    --subnet-prefixes 10.10.0.0/28 \
    --output none

  az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
    --name snet-dmz-shared --address-prefixes 10.50.0.0/24 --output none

  az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
    --name snet-mgmt --address-prefixes 10.99.0.0/24 --output none

  echo "Subredes base creadas (snet-team<N> se crean con 'add-team <N>')."
}

register_aci_provider() {
  echo "== Paso 3/4: Registrar provider Microsoft.ContainerInstance =="
  az provider register --namespace Microsoft.ContainerInstance
  echo "Esperando a que quede 'Registered' (puede tardar 1-2 min)..."
  until [[ "$(az provider show --namespace Microsoft.ContainerInstance --query registrationState --output tsv)" == "Registered" ]]; do
    sleep 5
  done
  echo "Provider registrado."
}

delegate_dmz_subnet() {
  echo "== Paso 4/4: Delegar snet-dmz-shared a ACI =="
  az network vnet subnet update \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name snet-dmz-shared \
    --delegations Microsoft.ContainerInstance/containerGroups \
    --output none
  echo "snet-dmz-shared delegada."
}

up() {
  check_prereqs
  create_resource_group
  create_vnet
  register_aci_provider
  delegate_dmz_subnet
  echo ""
  echo "== LISTO == Infraestructura base creada (RG, VNet, subredes, snet-dmz-shared delegada)."
  echo "Siguiente paso:"
  echo "  ./lab-azure.sh deploy-dmz     # despliega los servicios compartidos de la DMZ"
  echo "  ./lab-azure.sh add-team 1     # crea snet-team1 y despliega sus 4 contenedores"
}

# ---------------------------------------------------------------------------
# Funciones — DMZ compartida (snet-dmz-shared, 10.50.0.0/24)
# ---------------------------------------------------------------------------

deploy_dmz() {
  require_dockerhub_env
  echo "== Generando YAML de la DMZ (yamls/generate-dmz.sh) =="
  RESOURCE_GROUP="$RG" VNET="$VNET" SUBSCRIPTION_ID="$(get_subscription_id)" \
    "${YAMLS_DIR}/generate-dmz.sh"

  local gen="${YAMLS_DIR}/generated"

  echo "== Desplegando dmz-wiki-db =="
  local wikidb_ip
  wikidb_ip="$(deploy_container "${gen}/dmz-wiki-db.yaml")"
  echo "dmz-wiki-db IP: ${wikidb_ip}"
  sed -i "s|<WIKI_DB_IP>|${wikidb_ip}|" "${gen}/dmz-wiki.yaml"

  local svc
  for svc in dmz-wiki dmz-filesrv dmz-parking \
             dmz-decoy-printer dmz-decoy-nas dmz-decoy-legacy-web dmz-decoy-database \
             dmz-decoy-camera dmz-decoy-backup dmz-decoy-admin dmz-decoy-ftp \
             dmz-decoy-monitor dmz-decoy-git dmz-decoy-mail; do
    echo "== Desplegando ${svc} =="
    deploy_container "${gen}/${svc}.yaml" >/dev/null
  done

  echo ""
  echo "== DMZ desplegada: 15 contenedores, cada uno con su propia IP en snet-dmz-shared =="
  status
}

# ---------------------------------------------------------------------------
# Funciones — equipos (snet-teamN, 10.60.N.0/24)
# ---------------------------------------------------------------------------

add_team_subnet() {
  local team="$1"
  local prefix="10.60.${team}.0/24"
  echo "== Creando snet-team${team} (${prefix}) =="
  az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
    --name "snet-team${team}" --address-prefixes "$prefix" --output none
  az network vnet subnet update --resource-group "$RG" --vnet-name "$VNET" \
    --name "snet-team${team}" --delegations Microsoft.ContainerInstance/containerGroups --output none
  echo "snet-team${team} creada y delegada."
}

deploy_team() {
  local team="$1"

  case "$team" in
    ''|*[!0-9]*) echo "[ERROR] uso: $0 add-team <numero_de_equipo> (ej. 1, 2, 20)."; exit 1 ;;
  esac

  require_dockerhub_env

  [[ -f "${YAMLS_DIR}/.env.secrets" ]] || {
    echo "[ERROR] falta ${YAMLS_DIR}/.env.secrets (copia .env.secrets.example y rellena valores reales)."
    exit 1
  }

  add_team_subnet "$team"

  echo "== Generando YAML de team${team} (yamls/generate-team.sh) =="
  RESOURCE_GROUP="$RG" VNET="$VNET" SUBSCRIPTION_ID="$(get_subscription_id)" \
    "${YAMLS_DIR}/generate-team.sh" "$team"

  local gen="${YAMLS_DIR}/generated"

  echo "== Desplegando team${team}-database =="
  local db_ip
  db_ip="$(deploy_container "${gen}/team${team}-database.yaml")"
  echo "team${team}-database IP: ${db_ip}"
  sed -i "s|<DATABASE_IP>|${db_ip}|" "${gen}/team${team}-webapp.yaml"

  echo "== Desplegando team${team}-webapp =="
  local webapp_ip
  webapp_ip="$(deploy_container "${gen}/team${team}-webapp.yaml")"
  echo "team${team}-webapp IP: ${webapp_ip}"
  sed -i "s|<WEBAPP_IP>|${webapp_ip}|" "${gen}/team${team}-xss-bot.yaml"

  echo "== Desplegando team${team}-xss-bot =="
  deploy_container "${gen}/team${team}-xss-bot.yaml" >/dev/null

  echo "== Desplegando team${team}-linux-server =="
  deploy_container "${gen}/team${team}-linux-server.yaml" >/dev/null

  echo ""
  echo "== team${team} desplegado: 4 contenedores, cada uno con su propia IP en snet-team${team} =="
  status
}

# ---------------------------------------------------------------------------
# Estado y destrucción
# ---------------------------------------------------------------------------

status() {
  echo "== Container groups en ${RG} =="
  az container list --resource-group "$RG" \
    --query "[].{nombre:name, estado:instanceView.state, ip:ipAddress.ip}" \
    --output table 2>/dev/null || echo "Sin container groups (o el RG no existe todavía)."
}

down() {
  echo "== Destruyendo TODO: se borra el Resource Group completo =="
  read -p "Esto elimina '$RG' y TODO lo que contiene. ¿Confirmas? (escribe 'si'): " CONFIRM
  if [[ "$CONFIRM" != "si" ]]; then
    echo "Cancelado."
    exit 0
  fi
  az group delete --name "$RG" --yes --no-wait
  echo "Borrado en curso (--no-wait). Verifica con: az group exists --name $RG"
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
case "${1:-}" in
  up)         up ;;
  deploy-dmz) deploy_dmz ;;
  add-team)   shift; deploy_team "${1:-}" ;;
  status)     status ;;
  down)       down ;;
  *)
    echo "Uso: $0 {up|deploy-dmz|add-team <N>|status|down}"
    exit 1
    ;;
esac

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
#   ./lab-azure.sh deploy-dmz    # despliega los 13 contenedores compartidos de la DMZ (sin wiki)
#   ./lab-azure.sh deploy-wg-gateway # crea vm-wg-gateway en snet-wg-gateway (IP publica,
#                                 # WireGuard UDP 51820) + peer admin -- correr antes del primer
#                                 # add-team para que los equipos ya salgan con su tunel. NO
#                                 # PROBADO todavia, ver docs/plans/wireguard-vpn-gateway.md
#   ./lab-azure.sh add-team 1    # crea snet-team1, despliega sus 4 contenedores y (si el gateway
#                                 # ya existe) su peer WireGuard + yamls/generated/wg-clients/team1.conf
#   ./lab-azure.sh add-team 2    # idem para team2 (repetir por cada equipo)
#   ./lab-azure.sh add-team-range 1 20   # add-team 1..20 secuencial, se detiene en el primer error
#   ./lab-azure.sh add-team-range 1 20 4 # idem pero 4 equipos a la vez (subnets/peers WG siguen
#                                 # secuenciales, ver add_team_range() para el porqué)
#   ./lab-azure.sh deploy-wiki-vm # crea vm-wiki en snet-dmz-vm y levanta wiki+wiki-db via
#                                 # docker-compose -- NO PROBADO todavía, ver docs/plans/wiki-on-vm.md
#                                 # (cuota de VM desbloqueada 2026-08-08 tras upgrade a Pay-As-You-Go,
#                                 # 10 vCPUs StandardDsv7Family en eastus2)
#   ./lab-azure.sh test [N]      # atajo: up + deploy-dmz + add-team N (N=1 si se omite) -- todo
#                                # el laboratorio de una vez para pruebas rapidas (sin gateway VPN
#                                # a proposito, ver nota en deploy_wg_gateway())
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
WG_CLIENTS_DIR="${YAMLS_DIR}/generated/wg-clients"
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

# Espera hasta que un container group tenga IP asignada. Los container groups inyectados en una
# subred (VNet integration) son notoriamente lentos/inestables para que Azure les asigne la IP --
# 'az container create' puede devolver antes de que ipAddress.ip este poblado. Reintenta con
# timeout en vez de propagar un valor vacio.
wait_for_ip() {
  local name="$1"
  local max_tries=30 tries=0 ip=""
  until [[ -n "$ip" ]] || (( tries >= max_tries )); do
    ip="$(az container show --resource-group "$RG" --name "$name" --query ipAddress.ip --output tsv 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
      tries=$((tries + 1))
      echo "  ... ${name} sin IP todavia (intento ${tries}/${max_tries}), esperando 10s" >&2
      sleep 10
    fi
  done
  if [[ -z "$ip" ]]; then
    echo "[ERROR] ${name}: no se pudo obtener IP tras $((max_tries * 10 / 60)) min. Revisa:" >&2
    echo "  az container show -g ${RG} -n ${name} --query \"{estado:instanceView.state, ip:ipAddress.ip}\" -o table" >&2
    echo "  az container logs -g ${RG} -n ${name}" >&2
    exit 1
  fi
  echo "$ip"
}

# Despliega un container group desde un YAML y devuelve su IP privada por stdout (con reintentos).
# Los echo de progreso van al llamador, no aquí, para no contaminar la captura por $(...).
deploy_container() {
  local file="$1"
  local name
  name="$(basename "$file" .yaml)"
  az container create --resource-group "$RG" --file "$file" --output none
  wait_for_ip "$name"
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

  # DMZ paralela para servicios que no corren en ACI (ver docs/plans/wiki-on-vm.md): a diferencia
  # de snet-dmz-shared, esta NO se delega a ACI, así que admite VMs. dmz-wiki/dmz-wiki-db migran
  # aquí (docker-compose en una VM) el día que haya cuota de VM -- por ahora la subred solo queda
  # creada y vacía, no bloquea nada del flujo actual.
  az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
    --name snet-dmz-vm --address-prefixes 10.51.0.0/24 --output none

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
  echo "  ./lab-azure.sh deploy-wiki-vm # crea vm-wiki (wiki+wiki-db) en snet-dmz-vm"
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

  # dmz-wiki / dmz-wiki-db NO se despliegan aquí como contenedores ACI: BookStack
  # (s6-overlay v3) exige PID 1 real, que ACI+VNet no garantiza -- confirmado
  # determinísticamente (ExitCode 100, CrashLoopBackOff). Migrados a una VM con
  # docker-compose vía './lab-azure.sh deploy-wiki-vm' (ver docs/plans/wiki-on-vm.md).
  # generate-dmz.sh igual genera dmz-wiki.yaml/dmz-wiki-db.yaml a partir de sus plantillas
  # (quedan sin usar) porque no vale la pena bifurcar el generador solo por esto.
  local svc
  for svc in dmz-filesrv dmz-parking \
             dmz-decoy-printer dmz-decoy-nas dmz-decoy-legacy-web dmz-decoy-database \
             dmz-decoy-camera dmz-decoy-backup dmz-decoy-admin dmz-decoy-ftp \
             dmz-decoy-monitor dmz-decoy-git dmz-decoy-mail; do
    echo "== Desplegando ${svc} =="
    deploy_container "${gen}/${svc}.yaml" >/dev/null
  done

  echo ""
  echo "== DMZ desplegada: 13 contenedores, cada uno con su propia IP en snet-dmz-shared =="
  echo "== wiki queda pendiente: ./lab-azure.sh deploy-wiki-vm (VM en snet-dmz-vm) =="
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

validate_team_num() {
  case "$1" in
    ''|*[!0-9]*) echo "[ERROR] numero de equipo invalido: '${1:-}' (ej. 1, 2, 20)."; exit 1 ;;
  esac
}

require_team_prereqs() {
  require_dockerhub_env
  [[ -f "${YAMLS_DIR}/.env.secrets" ]] || {
    echo "[ERROR] falta ${YAMLS_DIR}/.env.secrets (copia .env.secrets.example y rellena valores reales)."
    exit 1
  }
}

# Genera y despliega los 4 contenedores de un equipo (sin subnet, sin peer WireGuard, sin
# status) -- separado de deploy_team() para poder correrlo en paralelo entre equipos en
# add_team_range() con concurrencia > 1. La cadena database->webapp->xss-bot (cada uno necesita
# la IP del anterior) sigue siendo secuencial DENTRO de un equipo; lo que se paraleliza es entre
# equipos, que son completamente independientes entre sí.
deploy_team_workload() {
  local team="$1"

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

  echo "== team${team} desplegado: 4 contenedores, cada uno con su propia IP en snet-team${team} =="
}

deploy_team() {
  local team="$1"
  validate_team_num "$team"
  require_team_prereqs

  add_team_subnet "$team"
  deploy_team_workload "$team"

  echo ""
  create_wg_team_peer "$team"

  status
}

add_team_range() {
  local start="$1" end="$2" concurrency="${3:-1}"

  case "$start" in ''|*[!0-9]*) echo "[ERROR] uso: $0 add-team-range <inicio> <fin> [paralelismo] (ej. 1 20 4)."; exit 1 ;; esac
  case "$end" in ''|*[!0-9]*) echo "[ERROR] uso: $0 add-team-range <inicio> <fin> [paralelismo] (ej. 1 20 4)."; exit 1 ;; esac
  case "$concurrency" in ''|*[!0-9]*|0) echo "[ERROR] <paralelismo> debe ser un entero >= 1."; exit 1 ;; esac
  if (( start > end )); then
    echo "[ERROR] <inicio> (${start}) no puede ser mayor que <fin> (${end})."
    exit 1
  fi

  if (( concurrency == 1 )); then
    echo "== Desplegando equipos ${start}..${end} (secuencial, se detiene en el primer error) =="
    local team
    for (( team = start; team <= end; team++ )); do
      echo ""
      echo "== [$((team - start + 1))/$((end - start + 1))] team${team} =="
      deploy_team "$team"
    done
    echo ""
    echo "== LISTO: equipos ${start}..${end} desplegados =="
    status
    return
  fi

  # Modo paralelo: subnets y peers WireGuard se quedan secuenciales a propósito.
  #   - Subnets: 'az network vnet subnet create' concurrentes sobre la MISMA VNet suelen chocar
  #     con 409 AnotherOperationInProgress en Azure -- crear todas antes de paralelizar evita esa
  #     carrera.
  #   - Peers WireGuard: create_wg_peer corre scripts remotos en vm-wg-gateway que leen/escriben
  #     la config de wg0 -- correrlos en paralelo arriesga corromper esa config compartida.
  # Lo que sí se paraleliza (que es lo lento: generar YAML + esperar 4 IPs por equipo) es
  # deploy_team_workload, con tope de concurrencia via job control de bash.
  require_team_prereqs

  echo "== Desplegando equipos ${start}..${end} (paralelo x${concurrency}) =="
  echo "== Paso 1: subredes (secuencial, evita 409 de Azure en la misma VNet) =="
  local team
  for (( team = start; team <= end; team++ )); do
    add_team_subnet "$team"
  done

  echo ""
  echo "== Paso 2: contenedores por equipo (paralelo x${concurrency}) =="
  local failed_file
  failed_file="$(mktemp)"
  for (( team = start; team <= end; team++ )); do
    while (( $(jobs -rp | wc -l) >= concurrency )); do
      wait -n || true
    done
    (
      if ! deploy_team_workload "$team" 2>&1 | sed -u "s/^/[team${team}] /"; then
        echo "$team" >> "$failed_file"
      fi
    ) &
  done
  wait

  if [[ -s "$failed_file" ]]; then
    echo ""
    echo "[ERROR] equipos que fallaron: $(sort -n "$failed_file" | xargs)"
    echo "        revisa sus contenedores y vuelve a correr 'add-team <N>' solo para esos."
    rm -f "$failed_file"
    exit 1
  fi
  rm -f "$failed_file"

  echo ""
  echo "== Paso 3: peers WireGuard (secuencial, evita chocar sobre vm-wg-gateway) =="
  for (( team = start; team <= end; team++ )); do
    create_wg_team_peer "$team"
  done

  echo ""
  echo "== LISTO: equipos ${start}..${end} desplegados (paralelo x${concurrency}) =="
  status
}

# ---------------------------------------------------------------------------
# Estado y destrucción
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Funciones — VM del wiki (snet-dmz-vm, 10.51.0.0/24)
# ---------------------------------------------------------------------------
#
# NO PROBADO. Ver docs/plans/wiki-on-vm.md -- escrito mientras la cuenta no tenía cuota de VM
# (Microsoft.Compute en 0 para toda familia en eastus2, Azure for Students no elegible para
# pedir aumento). Cuota desbloqueada 2026-08-08 (upgrade a Pay-As-You-Go, 10 vCPUs
# StandardDsv7Family) pero el flujo completo (az vm create + run-command + docker compose)
# sigue sin correrse ni una vez -- primera corrida real, revisar contra la realidad.
create_wiki_vm() {
  local vm_size="${WIKI_VM_SIZE:-Standard_D2s_v7}"

  echo "== VM del wiki: primera corrida real, ver docs/plans/wiki-on-vm.md =="
  echo "== Generando docker-compose (yamls/generate-wiki-vm.sh) =="
  "${YAMLS_DIR}/generate-wiki-vm.sh"

  echo "== az vm create: vm-wiki (${vm_size}, snet-dmz-vm, sin IP publica) =="
  az vm create \
    --resource-group "$RG" \
    --name vm-wiki \
    --image Ubuntu2204 \
    --size "$vm_size" \
    --vnet-name "$VNET" \
    --subnet snet-dmz-vm \
    --admin-username azureuser \
    --generate-ssh-keys \
    --public-ip-address "" \
    --nsg "" \
    --custom-data "${YAMLS_DIR}/wiki-vm/cloud-init.yaml" \
    --output table

  echo "== Esperando a que Docker quede listo (cloud-init) =="
  local tries=0 max_tries=30
  until az vm run-command invoke --resource-group "$RG" --name vm-wiki \
          --command-id RunShellScript --scripts "docker version" \
          --query "value[0].message" --output tsv 2>/dev/null | grep -q "Server:"; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] docker no quedó listo tras $((max_tries * 15 / 60)) min. Revisa manualmente:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-wiki --command-id RunShellScript --scripts 'cloud-init status --long'" >&2
      exit 1
    fi
    echo "  ... docker aún no listo (intento ${tries}/${max_tries}), esperando 15s"
    sleep 15
  done

  echo "== Copiando docker-compose.yml a la VM y desplegando (wiki + wiki-db) =="
  local compose_b64
  compose_b64="$(base64 -w0 "${YAMLS_DIR}/generated/wiki-vm-docker-compose.yml")"
  az vm run-command invoke \
    --resource-group "$RG" --name vm-wiki \
    --command-id RunShellScript \
    --scripts "mkdir -p /opt/wiki && echo '${compose_b64}' | base64 -d > /opt/wiki/docker-compose.yml && cd /opt/wiki && docker compose up -d" \
    --output table

  local vm_ip
  vm_ip="$(az vm list-ip-addresses -g "$RG" -n vm-wiki --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv)"
  echo ""
  echo "== VM del wiki desplegada (IP privada: ${vm_ip}) — NO VERIFICADO, revisar manualmente =="
  echo "  az vm run-command invoke -g ${RG} -n vm-wiki --command-id RunShellScript --scripts 'docker compose -f /opt/wiki/docker-compose.yml ps'"
}

# ---------------------------------------------------------------------------
# Funciones — Gateway WireGuard (snet-wg-gateway, 10.10.0.0/28)
# ---------------------------------------------------------------------------
#
# NO PROBADO. Ver docs/plans/wireguard-vpn-gateway.md. Unico punto de entrada al lab: VM con
# IP publica + WireGuard (UDP 51820). El control de acceso real (que puede alcanzar cada peer)
# NO es un NSG -- es iptables en la propia VM, con una regla FORWARD por peer scoped a sus CIDR
# permitidos y politica DROP por defecto. add-peer.sh.tpl es la unica pieza que aplica esa regla;
# create_wg_peer la resuelve localmente con envsubst y la manda completa como un solo string a
# 'az vm run-command invoke' (mismo patron que el one-liner base64 de create_wiki_vm).

create_wg_nsg() {
  echo "== NSG dedicado para snet-wg-gateway: solo UDP 51820 entrante desde Internet =="
  az network nsg create --resource-group "$RG" --name nsg-wg-gateway --location "$LOCATION" --output none

  az network nsg rule create \
    --resource-group "$RG" --nsg-name nsg-wg-gateway \
    --name allow-wireguard-inbound \
    --priority 100 --direction Inbound --access Allow --protocol Udp \
    --source-address-prefixes Internet --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 51820 \
    --output none

  # Las reglas default de Azure (DenyAllInBound a prioridad 65500) ya cubren todo lo demas --
  # no hace falta una regla deny explicita. Este NSG queda deliberadamente mas restrictivo que
  # el default de la VNet (que permite AllowVnetInBound): snet-wg-gateway es la unica subred que
  # no debe confiar en "cualquier cosa dentro de la VNet" como origen.
  az network vnet subnet update \
    --resource-group "$RG" --vnet-name "$VNET" --name snet-wg-gateway \
    --network-security-group nsg-wg-gateway --output none
}

# create_wg_peer <nombre> <tunnel_ip/32> <cidrs_permitidos_separados_por_espacio>
# Compartida entre el peer admin (deploy_wg_gateway) y los peers de equipo (create_wg_team_peer).
create_wg_peer() {
  local name="$1" tunnel_ip="$2" allowed_cidrs="$3"

  echo "== Peer WireGuard '${name}': generando/aplicando en vm-wg-gateway (tunnel ${tunnel_ip}) =="

  local rendered
  rendered="$(PEER_NAME="$name" TUNNEL_IP="$tunnel_ip" ALLOWED_CIDRS="$allowed_cidrs" \
    envsubst '${PEER_NAME} ${TUNNEL_IP} ${ALLOWED_CIDRS}' < "${YAMLS_DIR}/wg-gateway/remote/add-peer.sh.tpl")"

  local out clean privkey pubkey
  out="$(az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway \
    --command-id RunShellScript --scripts "$rendered" \
    --query "value[0].message" --output tsv)"
  clean="$(sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' <<<"$out")"
  privkey="$(grep '^PRIVKEY=' <<<"$clean" | cut -d= -f2-)"
  pubkey="$(grep '^PUBKEY=' <<<"$clean" | cut -d= -f2-)"

  if [[ -z "$privkey" || -z "$pubkey" ]]; then
    echo "[ERROR] no se pudo extraer las keys del peer '${name}'. Salida cruda de run-command:" >&2
    echo "$out" >&2
    exit 1
  fi

  local server_out server_clean server_pubkey gw_ip
  server_out="$(az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway \
    --command-id RunShellScript --scripts "$(cat "${YAMLS_DIR}/wg-gateway/remote/init-server-keys.sh")" \
    --query "value[0].message" --output tsv)"
  server_clean="$(sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' <<<"$server_out")"
  server_pubkey="$(grep '^PUBKEY=' <<<"$server_clean" | cut -d= -f2-)"

  gw_ip="$(az vm list-ip-addresses --resource-group "$RG" --name vm-wg-gateway \
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)"

  mkdir -p "$WG_CLIENTS_DIR"
  PEER_NAME="$name" \
    CLIENT_PRIVKEY="$privkey" \
    CLIENT_TUNNEL_IP="$tunnel_ip" \
    CLIENT_DNS="1.1.1.1" \
    SERVER_PUBKEY="$server_pubkey" \
    GATEWAY_PUBLIC_IP="$gw_ip" \
    CLIENT_ALLOWED_IPS="${allowed_cidrs// /, }" \
    "${YAMLS_DIR}/generate-wg-client.sh"
}

# Se llama desde deploy_team() al final. Guardado, no bloqueante: si el gateway todavia no
# existe, el equipo queda igual desplegado (los 4 contenedores ya funcionan solos dentro de la
# VNet) solo que sin tunel VPN hasta que se corra deploy-wg-gateway y se repita add-team.
create_wg_team_peer() {
  local team="$1"
  if ! az vm show --resource-group "$RG" --name vm-wg-gateway --output none 2>/dev/null; then
    echo "[WARN] vm-wg-gateway no existe -- team${team} desplegado, pero SIN acceso VPN todavia."
    echo "        Corre './lab-azure.sh deploy-wg-gateway' y luego repite 'add-team ${team}' para generar su peer."
    return 0
  fi
  create_wg_peer "team${team}" "10.200.${team}.2/32" "10.60.${team}.0/24 10.50.0.0/24 10.51.0.0/24"
}

deploy_wg_gateway() {
  local vm_size="${WG_GW_VM_SIZE:-Standard_D2s_v7}"

  echo "== VM del gateway WireGuard: primera corrida real, ver docs/plans/wireguard-vpn-gateway.md =="
  create_wg_nsg

  echo "== az vm create: vm-wg-gateway (${vm_size}, snet-wg-gateway, CON IP publica) =="
  az vm create \
    --resource-group "$RG" \
    --name vm-wg-gateway \
    --image Ubuntu2204 \
    --size "$vm_size" \
    --vnet-name "$VNET" \
    --subnet snet-wg-gateway \
    --admin-username azureuser \
    --generate-ssh-keys \
    --public-ip-address vm-wg-gateway-pip \
    --public-ip-sku Standard \
    --nsg "" \
    --custom-data "${YAMLS_DIR}/wg-gateway/cloud-init.yaml" \
    --output table

  echo "== Esperando a que wg0 quede activo (cloud-init) =="
  local tries=0 max_tries=30
  until az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway \
          --command-id RunShellScript --scripts "systemctl is-active wg-quick@wg0" \
          --query "value[0].message" --output tsv 2>/dev/null | grep -q "^active$"; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] wg0 no quedó activo tras $((max_tries * 15 / 60)) min. Revisa manualmente:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-wg-gateway --command-id RunShellScript --scripts 'cloud-init status --long'" >&2
      exit 1
    fi
    echo "  ... wg0 aún no activo (intento ${tries}/${max_tries}), esperando 15s"
    sleep 15
  done

  local gw_ip
  gw_ip="$(az vm list-ip-addresses --resource-group "$RG" --name vm-wg-gateway \
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)"
  echo "IP publica del gateway: ${gw_ip}"

  echo "== Creando peer admin =="
  create_wg_peer "admin" "10.200.0.2/32" "10.0.0.0/8"

  echo ""
  echo "== Gateway WireGuard desplegado. Cliente admin: ${WG_CLIENTS_DIR}/admin.conf =="
  echo "== NO VERIFICADO end-to-end -- probar conectando ese .conf desde un cliente real antes de confiar =="
}

# az container list nunca trae instanceView poblado (limitación de la API/CLI, no filtro
# nuestro) -- provisioningState tampoco sirve solo, un container group puede quedar en
# 'Succeeded' con un contenedor en CrashLoopBackOff adentro (visto con dmz-wiki en ACI). Por
# eso el estado real hay que pedirlo por contenedor con 'az container show'.
print_container_states() {
  local prefix="$1"
  local names
  names="$(az container list --resource-group "$RG" --query "[?starts_with(name, '${prefix}')].name" --output tsv 2>/dev/null | sort || true)"
  if [[ -z "$names" ]]; then
    echo "  (ninguno desplegado todavía)"
    return
  fi
  printf "  %-22s %-18s %-15s %s\n" "NOMBRE" "ESTADO" "IP" "RESTARTS"
  local name
  while IFS=$'\t' read -r nombre estado ip restarts; do
    printf "  %-22s %-18s %-15s %s\n" "$nombre" "${estado:-?}" "${ip:-?}" "${restarts:-0}"
  done < <(
    for name in $names; do
      az container show --resource-group "$RG" --name "$name" \
        --query "[[name, instanceView.state, ipAddress.ip, containers[0].instanceView.restartCount]]" \
        --output tsv
    done
  )
}

status() {
  echo "== DMZ compartida (snet-dmz-shared) =="
  print_container_states "dmz-"

  echo ""
  echo "== DMZ-VM (snet-dmz-vm) =="
  if az vm show --resource-group "$RG" --name vm-wiki --output none 2>/dev/null; then
    local vm_power vm_ip
    vm_power="$(az vm get-instance-view --resource-group "$RG" --name vm-wiki \
      --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" --output tsv)"
    vm_ip="$(az vm list-ip-addresses --resource-group "$RG" --name vm-wiki \
      --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv)"
    printf "  %-22s %-18s %s\n" "vm-wiki" "$vm_power" "$vm_ip"
    if [[ "$vm_power" == "VM running" ]]; then
      echo "  docker compose (wiki + wiki-db):"
      az vm run-command invoke --resource-group "$RG" --name vm-wiki --command-id RunShellScript \
        --scripts "docker compose -f /opt/wiki/docker-compose.yml ps --format 'table {{.Name}}\t{{.Status}}'" \
        --query "value[0].message" --output tsv 2>/dev/null \
        | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' | sed 's/^/    /'
    fi
  else
    echo "  vm-wiki no existe (correr: ./lab-azure.sh deploy-wiki-vm)"
  fi

  echo ""
  echo "== Gateway WireGuard (snet-wg-gateway) =="
  if az vm show --resource-group "$RG" --name vm-wg-gateway --output none 2>/dev/null; then
    local wg_power wg_pub_ip
    wg_power="$(az vm get-instance-view --resource-group "$RG" --name vm-wg-gateway \
      --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" --output tsv)"
    wg_pub_ip="$(az vm list-ip-addresses --resource-group "$RG" --name vm-wg-gateway \
      --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)"
    printf "  %-22s %-18s %s\n" "vm-wg-gateway" "$wg_power" "$wg_pub_ip"
    if [[ "$wg_power" == "VM running" ]]; then
      echo "  wg show wg0 (peers / tunnel IPs / ultimo handshake):"
      az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway --command-id RunShellScript \
        --scripts "wg show wg0" \
        --query "value[0].message" --output tsv 2>/dev/null \
        | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' | sed 's/^/    /'
    fi
  else
    echo "  vm-wg-gateway no existe (correr: ./lab-azure.sh deploy-wg-gateway)"
  fi

  echo ""
  echo "== Equipos (snet-teamN) =="
  print_container_states "team"
}

test_deploy() {
  local team="${1:-1}"
  echo "== TEST: infraestructura base + DMZ completa + team${team} =="
  up
  deploy_dmz
  deploy_team "$team"
  echo ""
  echo "== TEST LISTO: DMZ completa + team${team} desplegados =="
  status
}

down() {
  echo "== Destruyendo TODO: se borra el Resource Group completo =="
  read -p "Esto elimina '$RG' y TODO lo que contiene. ¿Confirmas? (escribe 'si'): " CONFIRM
  if [[ "$CONFIRM" != "si" ]]; then
    echo "Cancelado."
    exit 0
  fi
  az group delete --name "$RG" --yes --no-wait
  if az group exists --name NetworkWatcherRG --output tsv | grep -qi true; then
    az group delete --name NetworkWatcherRG --yes --no-wait
  fi
  echo "Borrado en curso (--no-wait). Verifica con: az group exists --name $RG"
  echo "(y az group exists --name NetworkWatcherRG)"
}

# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------
case "${1:-}" in
  up)                up ;;
  deploy-dmz)        deploy_dmz ;;
  add-team)          shift; deploy_team "${1:-}" ;;
  add-team-range)    shift; add_team_range "${1:-}" "${2:-}" "${3:-1}" ;;
  deploy-wiki-vm)    create_wiki_vm ;;
  deploy-wg-gateway) deploy_wg_gateway ;;
  wg-team-peer)
    # Backfill: genera el peer/tunel WireGuard de un equipo que ya fue desplegado con add-team
    # ANTES de que existiera el gateway (create_wg_team_peer se saltó con un warning en ese
    # momento). No recrea el equipo, solo la parte VPN -- idempotente igual que add-team.
    shift
    team="${1:-}"
    case "$team" in
      ''|*[!0-9]*) echo "[ERROR] uso: $0 wg-team-peer <numero_de_equipo> (ej. 1, 2, 20)."; exit 1 ;;
    esac
    create_wg_team_peer "$team"
    ;;
  test)              shift; test_deploy "${1:-1}" ;;
  status)            status ;;
  down)              down ;;
  *)
    echo "Uso: $0 {up|deploy-dmz|add-team <N>|add-team-range <inicio> <fin> [paralelismo]|deploy-wiki-vm|deploy-wg-gateway|wg-team-peer <N>|test [N]|status|down}"
    exit 1
    ;;
esac

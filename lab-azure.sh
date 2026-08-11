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
#                                 # add-team para que los equipos ya salgan con su tunel.
#                                 # Validado end-to-end 2026-08-08, ver
#                                 # docs/plans/wireguard-vpn-gateway.md
#   ./lab-azure.sh add-team 1    # crea snet-team1, despliega sus 4 contenedores y (si el gateway
#                                 # ya existe) su peer WireGuard + yamls/generated/wg-clients/team1.conf
#   ./lab-azure.sh add-team 2    # idem para team2 (repetir por cada equipo)
#   ./lab-azure.sh add-team-range 1 20   # add-team 1..20 secuencial, se detiene en el primer error
#   ./lab-azure.sh add-team-range 1 20 4 # idem pero 4 equipos a la vez (subnets/peers WG siguen
#                                 # secuenciales, ver add_team_range() para el porqué)
#   ./lab-azure.sh deploy-wiki-vm # crea vm-wiki en snet-dmz-vm y levanta wiki+wiki-db via
#                                 # docker-compose -- validado end-to-end 2026-08-08, ver
#                                 # docs/plans/wiki-on-vm.md (cuota de VM desbloqueada ese mismo
#                                 # dia tras upgrade a Pay-As-You-Go, 10 vCPUs
#                                 # StandardDsv7Family en eastus2)
#   ./lab-azure.sh deploy-ctfd-vm # crea vm-ctfd en snet-dmz-vm (nginx + ctfd + mariadb + redis via
#                                 # docker-compose) -- F2 de docs/plans/ctfd-deployment.md, requiere
#                                 # bloque CTFD_* en yamls/.env.secrets y la imagen
#                                 # <DOCKERHUB_USER>/sabana-corp-ctfd ya publicada
#   ./lab-azure.sh deploy-monitor-vm # crea vm-monitor en snet-mgmt (Prometheus + blackbox_exporter
#                                 # + Grafana + node_exporter, sin IP publica, managed identity
#                                 # Reader sobre el RG) -- F1+F2 de
#                                 # docs/plans/observability-monitoring.md
#   ./lab-azure.sh dns-sync            # empuja el estado LOCAL (yamls/generated/dns/*.hosts) al
#                                # dnsmasq de vm-wg-gateway en una sola invocacion (O(1)) -- ver
#                                # docs/plans/internal-dns.md
#   ./lab-azure.sh dns-sync --from-azure # reconstruye TODA la zona desde 'az container list' y
#                                # la empuja -- comando de reparacion / chequeo pre-evento
#   ./lab-azure.sh dns-check <fqdn>  # resuelve <fqdn> desde el gateway y lo compara con la IP
#                                # real de Azure
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

# DNS interno del lab (ver docs/plans/internal-dns.md). LAB_DOMAIN vive en esta unica variable a
# proposito -- cambiarlo es una edicion aqui + un dns-sync. WG_GW_PRIVATE_IP/WG_GW_TUNNEL_IP son
# constantes de diseño (la primera se fija con --private-ip-address en deploy_wg_gateway, la
# segunda la fija yamls/wg-gateway/cloud-init.yaml) -- no hay que descubrirlas en tiempo de
# generacion.
LAB_DOMAIN="${LAB_DOMAIN:-sabanacorp.internal}"
WG_GW_PRIVATE_IP="10.10.0.4"
WG_GW_TUNNEL_IP="10.200.0.1"
DNS_DIR="${YAMLS_DIR}/generated/dns"

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
  # de snet-dmz-shared, esta NO se delega a ACI, así que admite VMs. Aquí vive vm-wiki
  # (wiki + wiki-db con docker-compose), desplegada por './lab-azure.sh deploy-wiki-vm' y
  # validada end-to-end 2026-08-08.
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
    LAB_DOMAIN="$LAB_DOMAIN" LAB_DNS_SERVER="$(lab_dns_server)" \
    "${YAMLS_DIR}/generate-dmz.sh"

  local gen="${YAMLS_DIR}/generated"

  # El wiki (BookStack + MariaDB) NO vive aquí: s6-overlay v3 exige PID 1 real, que ACI+VNet
  # no garantiza -- confirmado determinísticamente (ExitCode 100, CrashLoopBackOff). Corre en
  # vm-wiki con docker-compose vía './lab-azure.sh deploy-wiki-vm' (ver docs/plans/wiki-on-vm.md).
  # Sus plantillas de ACI (dmz-wiki*.yaml.tpl) fueron borradas: no se desplegaban.
  local svc
  for svc in dmz-filesrv dmz-parking \
             dmz-decoy-printer dmz-decoy-nas dmz-decoy-legacy-web dmz-decoy-database \
             dmz-decoy-camera dmz-decoy-backup dmz-decoy-admin dmz-decoy-ftp \
             dmz-decoy-monitor dmz-decoy-git dmz-decoy-mail; do
    echo "== Desplegando ${svc} =="
    deploy_container "${gen}/${svc}.yaml" >/dev/null
  done

  echo "== Registrando DNS de la DMZ (dmz.hosts + infra.hosts) =="
  RESOURCE_GROUP="$RG" LAB_DOMAIN="$LAB_DOMAIN" WG_GW_TUNNEL_IP="$WG_GW_TUNNEL_IP" \
    "${YAMLS_DIR}/generate-dns-hosts.sh" dmz
  sync_lab_dns

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
    LAB_DOMAIN="$LAB_DOMAIN" LAB_DNS_SERVER="$(lab_dns_server)" \
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
  local bot_ip
  bot_ip="$(deploy_container "${gen}/team${team}-xss-bot.yaml")"

  echo "== Desplegando team${team}-linux-server =="
  local linux_ip
  linux_ip="$(deploy_container "${gen}/team${team}-linux-server.yaml")"

  # DNS: solo escritura LOCAL aqui (yamls/generated/dns/team<N>.hosts) -- nada de run-command.
  # Es lo que mantiene esta funcion segura de correr en paralelo entre equipos en
  # add_team_range(); el push al gateway (O(1), no por equipo) va en un paso secuencial aparte
  # (ver sync_lab_dns y "Mecanismo de escritura de la zona" en docs/plans/internal-dns.md).
  RESOURCE_GROUP="$RG" LAB_DOMAIN="$LAB_DOMAIN" WG_GW_TUNNEL_IP="$WG_GW_TUNNEL_IP" \
    "${YAMLS_DIR}/generate-dns-hosts.sh" team "$team" "$db_ip" "$webapp_ip" "$linux_ip" "$bot_ip"

  echo "== team${team} desplegado: 4 contenedores, cada uno con su propia IP en snet-team${team} =="
}

deploy_team() {
  local team="$1"
  validate_team_num "$team"
  require_team_prereqs

  add_team_subnet "$team"
  deploy_team_workload "$team"
  sync_lab_dns

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

  # Modo paralelo: subnets, DNS y peers WireGuard se quedan secuenciales a propósito.
  #   - Subnets: 'az network vnet subnet create' concurrentes sobre la MISMA VNet suelen chocar
  #     con 409 AnotherOperationInProgress en Azure -- crear todas antes de paralelizar evita esa
  #     carrera.
  #   - DNS (sync_lab_dns) y peers WireGuard: ambos corren 'az vm run-command invoke' contra
  #     vm-wg-gateway, que es de UN SOLO HILO por VM -- invocaciones concurrentes contra la misma
  #     VM se serializan o fallan con conflicto de operacion en curso. Regla general, no solo de
  #     los peers: TODA escritura sobre vm-wg-gateway va en un paso secuencial (ver
  #     docs/plans/internal-dns.md "Mecanismo de escritura de la zona y paralelismo").
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

  # Paso 2.5: UN solo push de DNS para todo el rango, no uno por equipo -- O(1), no O(N). Cada
  # deploy_team_workload de arriba ya escribio su team<N>.hosts local (sin tocar el gateway);
  # aqui se concatenan todos y se empujan en una sola invocacion de run-command. Va antes de los
  # peers (paso 3) porque ambos tocan vm-wg-gateway y esa VM solo procesa un run-command a la vez.
  echo ""
  echo "== Paso 2.5: sincronizando DNS (1 invocacion para ${start}..${end}) =="
  sync_lab_dns

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
# Validado end-to-end 2026-08-08. Ver docs/plans/wiki-on-vm.md para detalles.
# Cuota de VM desbloqueada tras upgrade a Pay-As-You-Go (10 vCPUs StandardDsv7Family).
create_wiki_vm() {
  local vm_size="${WIKI_VM_SIZE:-Standard_D2s_v7}"

  echo "== VM del wiki (validado 2026-08-08), ver docs/plans/wiki-on-vm.md =="
  echo "== Generando docker-compose (yamls/generate-wiki-vm.sh) =="
  LAB_DOMAIN="$LAB_DOMAIN" "${YAMLS_DIR}/generate-wiki-vm.sh"

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

  echo "== Registrando wiki.dmz en el DNS del lab =="
  RESOURCE_GROUP="$RG" LAB_DOMAIN="$LAB_DOMAIN" WG_GW_TUNNEL_IP="$WG_GW_TUNNEL_IP" \
    "${YAMLS_DIR}/generate-dns-hosts.sh" dmz
  sync_lab_dns

  echo ""
  echo "== VM del wiki desplegada (IP privada: ${vm_ip}) — Validada 2026-08-08, ver docs/plans/wiki-on-vm.md =="
  echo "  az vm run-command invoke -g ${RG} -n vm-wiki --command-id RunShellScript --scripts 'docker compose -f /opt/wiki/docker-compose.yml ps'"
}

# ---------------------------------------------------------------------------
# Funciones — VM de CTFd (snet-dmz-vm, comparte subred con vm-wiki)
# ---------------------------------------------------------------------------
#
# F2 de docs/plans/ctfd-deployment.md. Mismo patrón que create_wiki_vm(): cloud-init instala
# Docker (+ python3-pip aquí), se empuja el bundle generado (docker-compose.yml +
# conf/nginx/http.conf + seed/*) vía 'az vm run-command invoke'. A diferencia del wiki, los
# secretos SÍ vienen de yamls/.env.secrets (bloque CTFD_*) -- decisión explícita del plan, ver
# generate-ctfd-vm.sh.
#
# Al final corre, en orden, dos scripts vendored frescos desde ../sabana-corp-CTFd por
# generate-ctfd-vm.sh -- ninguno depende de que el operador esté conectado al túnel VPN admin:
#   1. seed_setup.py -- completa el wizard de /setup (nombre del evento, modo equipos, cuenta
#      admin) DENTRO del contenedor ctfd ('docker compose exec'), porque CTFd bloquea CUALQUIER
#      request -- incluida la API -- hasta que /setup esté hecho. No usa HTTP/CSRF: escribe
#      directo contra los modelos de CTFd con contexto de Flask.
#   2. seed_challenges.py -- carga challenges/flags contra la API REST, DESDE el host de la VM
#      (http://localhost), autenticado con CTFD_PRESET_ADMIN_TOKEN (yamls/.env.secrets): CTFd lo
#      acepta como Access Token de un admin que crea al vuelo (ver PRESET_ADMIN_TOKEN en
#      templates/ctfd-compose.yml.tpl), así que tampoco hace falta generar un token a mano por
#      la UI.
create_ctfd_vm() {
  local vm_size="${CTFD_VM_SIZE:-Standard_D2s_v7}"

  echo "== VM de CTFd (docs/plans/ctfd-deployment.md, F2) =="
  require_dockerhub_env

  local secrets_file="${YAMLS_DIR}/.env.secrets"
  [[ -f "$secrets_file" ]] || { echo "[ERROR] falta ${secrets_file}."; exit 1; }
  set -a
  # shellcheck disable=SC1090
  source "$secrets_file"
  set +a
  : "${CTFD_PRESET_ADMIN_TOKEN:?Falta CTFD_PRESET_ADMIN_TOKEN en yamls/.env.secrets}"

  echo "== az vm create: vm-ctfd (${vm_size}, snet-dmz-vm, sin IP publica) =="
  az vm create \
    --resource-group "$RG" \
    --name vm-ctfd \
    --image Ubuntu2204 \
    --size "$vm_size" \
    --vnet-name "$VNET" \
    --subnet snet-dmz-vm \
    --admin-username azureuser \
    --generate-ssh-keys \
    --public-ip-address "" \
    --nsg "" \
    --custom-data "${YAMLS_DIR}/ctfd-vm/cloud-init.yaml" \
    --output table

  local vm_ip
  vm_ip="$(az vm list-ip-addresses -g "$RG" -n vm-ctfd --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv)"

  # La IP se conoce recién ahora (tras 'az vm create'), así que el bundle se genera DESPUÉS de
  # crear la VM, no antes -- CTFD_VM_IP entra a TRUSTED_HOSTS (ver generate-ctfd-vm.sh) para que
  # acceder por IP directa (no solo por el FQDN del DNS interno) no tire 500. Necesario porque el
  # split-DNS de WireGuard no es confiable en clientes Linux (ver docs/plans/internal-dns.md) --
  # encontrado en la validación real 2026-08-11, un operador en Linux navegó por IP y CTFd lo
  # rechazó antes de este fix.
  echo "== Generando bundle (yamls/generate-ctfd-vm.sh) =="
  LAB_DOMAIN="$LAB_DOMAIN" CTFD_VM_IP="$vm_ip" "${YAMLS_DIR}/generate-ctfd-vm.sh"

  echo "== Esperando a que Docker + pip queden listos (cloud-init) =="
  local tries=0 max_tries=30
  until az vm run-command invoke --resource-group "$RG" --name vm-ctfd \
          --command-id RunShellScript --scripts "docker version && python3 -m pip --version" \
          --query "value[0].message" --output tsv 2>/dev/null | grep -q "Server:"; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] docker/pip no quedaron listos tras $((max_tries * 15 / 60)) min. Revisa manualmente:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-ctfd --command-id RunShellScript --scripts 'cloud-init status --long'" >&2
      exit 1
    fi
    echo "  ... vm-ctfd aún no lista (intento ${tries}/${max_tries}), esperando 15s"
    sleep 15
  done

  echo "== Copiando el bundle a vm-ctfd, instalando deps del seed y desplegando (nginx + ctfd + db + cache) =="
  local bundle_b64
  bundle_b64="$(tar -C "${YAMLS_DIR}/generated/ctfd" -czf - . | base64 -w0)"
  az vm run-command invoke \
    --resource-group "$RG" --name vm-ctfd \
    --command-id RunShellScript \
    --scripts "mkdir -p /opt/ctfd && echo '${bundle_b64}' | base64 -d | tar xzf - -C /opt/ctfd && \
      pip3 install -q -r /opt/ctfd/seed/requirements.txt && \
      cd /opt/ctfd && docker compose up -d" \
    --output table

  echo "== Registrando ctfd.dmz en el DNS del lab =="
  RESOURCE_GROUP="$RG" LAB_DOMAIN="$LAB_DOMAIN" WG_GW_TUNNEL_IP="$WG_GW_TUNNEL_IP" \
    "${YAMLS_DIR}/generate-dns-hosts.sh" dmz
  sync_lab_dns

  # 'az vm run-command invoke' devuelve exit 0 y "ProvisioningState/succeeded" AUNQUE el script
  # remoto termine con un exit code distinto de cero -- el resultado real vive solo en el texto de
  # value[0].message (bloques [stdout]/[stderr]). Encontrado en la primera corrida real
  # (2026-08-11): un curl -f fallando y un seed_challenges.py con traceback pasaron ambos
  # desapercibidos porque el código de abajo confiaba en el exit code de 'az' o usaba
  # '--output table' sin inspeccionar el mensaje. De aquí en adelante: capturar el mensaje,
  # imprimirlo siempre (nada de '--output table' silencioso) y decidir éxito/error por su
  # contenido, no por $?.

  echo "== Esperando a que CTFd responda en localhost (dentro de vm-ctfd) =="
  tries=0; max_tries=20
  local http_code
  while :; do
    http_code="$(az vm run-command invoke --resource-group "$RG" --name vm-ctfd \
      --command-id RunShellScript \
      --scripts "curl -s -o /dev/null -w '%{http_code}' http://localhost/api/v1/challenges" \
      --query "value[0].message" --output tsv 2>/dev/null \
      | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' | tr -d '[:space:]')"
    [[ "$http_code" =~ ^(2|3)[0-9][0-9]$ ]] && break
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] CTFd no respondió (último código HTTP: '${http_code:-sin respuesta}') tras $((max_tries * 15 / 60)) min. Revisa manualmente:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-ctfd --command-id RunShellScript --scripts 'docker compose -f /opt/ctfd/docker-compose.yml logs --tail 100'" >&2
      exit 1
    fi
    echo "  ... ctfd aún no responde (código '${http_code:-sin respuesta}', intento ${tries}/${max_tries}), esperando 15s"
    sleep 15
  done

  echo "== Completando /setup (seed_setup.py, corre dentro del contenedor ctfd via 'docker compose exec') =="
  local setup_msg
  setup_msg="$(az vm run-command invoke \
    --resource-group "$RG" --name vm-ctfd \
    --command-id RunShellScript \
    --scripts "cd /opt/ctfd && docker compose exec -T ctfd python3 - < seed/seed_setup.py" \
    --query "value[0].message" --output tsv 2>/dev/null)"
  echo "$setup_msg"
  if ! grep -qE "CTFd (ya esta )?configurado" <<<"$setup_msg"; then
    echo "[ERROR] seed_setup.py no confirmó éxito (ver mensaje arriba)." >&2
    exit 1
  fi

  echo "== Cargando challenges/flags (seed_challenges.py, vendored desde sabana-corp-CTFd) =="
  local publish_flag=""
  [[ "${CTFD_SEED_PUBLISH:-}" == "1" ]] && publish_flag="--publish"
  local seed_msg
  seed_msg="$(az vm run-command invoke \
    --resource-group "$RG" --name vm-ctfd \
    --command-id RunShellScript \
    --scripts "cd /opt/ctfd && CTFD_URL=http://localhost CTFD_API_TOKEN='${CTFD_PRESET_ADMIN_TOKEN}' python3 seed/seed_challenges.py --manifest seed/challenges.yml --env-file seed/flags.env ${publish_flag}" \
    --query "value[0].message" --output tsv 2>/dev/null)"
  echo "$seed_msg"
  if grep -q "^error:" <<<"$seed_msg" || ! grep -q "^OK  " <<<"$seed_msg"; then
    echo "[ERROR] seed_challenges.py no confirmó éxito (ver mensaje arriba)." >&2
    exit 1
  fi

  echo ""
  echo "== VM de CTFd desplegada (IP privada: ${vm_ip}) — ver docs/plans/ctfd-deployment.md (F2) =="
  echo "  http://${vm_ip} o http://ctfd.dmz.${LAB_DOMAIN} (via tunel VPN)"
  echo "  admin: ${CTFD_PRESET_ADMIN_EMAIL} / (password en yamls/.env.secrets, CTFD_PRESET_ADMIN_PASSWORD)"
  if [[ -n "$publish_flag" ]]; then
    echo "  Challenges cargados y PUBLICADOS (CTFD_SEED_PUBLISH=1)."
  else
    echo "  Challenges cargados OCULTOS -- correr con CTFD_SEED_PUBLISH=1 para publicarlos, o desde la UI."
  fi
  echo "  az vm run-command invoke -g ${RG} -n vm-ctfd --command-id RunShellScript --scripts 'docker compose -f /opt/ctfd/docker-compose.yml ps'"
}

# ---------------------------------------------------------------------------
# Funciones — VM de monitoreo (snet-mgmt, 10.99.0.0/24)
# ---------------------------------------------------------------------------
#
# F1+F2 de docs/plans/observability-monitoring.md: Prometheus + blackbox_exporter (sondeo externo,
# cero cambios en las imagenes de los retos) + Grafana (dashboard "muro de equipos" + alertas
# Unified sin contact points) + node_exporter (metricas propias + textfile collector). Mismo
# patron que create_wiki_vm(): cloud-init instala Docker (y aqui ademas Azure CLI), y el resto se
# empuja via 'az vm run-command invoke' -- solo que aca es un bundle entero (tar+base64), no un
# solo archivo, porque el stack tiene mas piezas (prometheus.yml, blackbox.yml, provisioning de
# Grafana, el script de descubrimiento).
#
# Managed identity con Reader SOLO sobre este Resource Group (nunca sobre la suscripcion) -- ver
# "Riesgos: la managed identity es el activo mas valioso de snet-mgmt" en el plan.
create_monitor_vm() {
  local vm_size="${MONITOR_VM_SIZE:-Standard_D2s_v7}"

  echo "== VM de monitoreo (docs/plans/observability-monitoring.md, F1+F2) =="
  echo "== Generando bundle (yamls/generate-monitor.sh) =="
  RESOURCE_GROUP="$RG" "${YAMLS_DIR}/generate-monitor.sh"

  echo "== az vm create: vm-monitor (${vm_size}, snet-mgmt, sin IP publica, managed identity) =="
  az vm create \
    --resource-group "$RG" \
    --name vm-monitor \
    --image Ubuntu2204 \
    --size "$vm_size" \
    --vnet-name "$VNET" \
    --subnet snet-mgmt \
    --admin-username azureuser \
    --generate-ssh-keys \
    --public-ip-address "" \
    --nsg "" \
    --assign-identity '[system]' \
    --custom-data "${YAMLS_DIR}/monitor/cloud-init.yaml" \
    --output table

  echo "== Asignando rol Reader (alcance: solo este Resource Group) a la managed identity =="
  local principal_id sub_id tries max_tries
  principal_id="$(az vm identity show --resource-group "$RG" --name vm-monitor --query principalId --output tsv)"
  sub_id="$(get_subscription_id)"
  tries=0; max_tries=10
  # Reintento: una identidad recien creada en Entra ID puede tardar unos segundos en propagar
  # antes de que 'role assignment create' la reconozca (PrincipalNotFound transitorio, no un
  # error real de permisos).
  until az role assignment create \
          --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
          --role Reader --scope "/subscriptions/${sub_id}/resourceGroups/${RG}" \
          --output none 2>/dev/null; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] no se pudo asignar el rol Reader tras ${max_tries} intentos." >&2
      exit 1
    fi
    echo "  ... identidad aun no propagada (intento ${tries}/${max_tries}), esperando 10s"
    sleep 10
  done

  echo "== Esperando a que Docker + Azure CLI queden listos (cloud-init) =="
  tries=0; max_tries=30
  until az vm run-command invoke --resource-group "$RG" --name vm-monitor \
          --command-id RunShellScript --scripts "docker version && az version" \
          --query "value[0].message" --output tsv 2>/dev/null | grep -q "Server:"; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] docker/az cli no quedaron listos tras $((max_tries * 15 / 60)) min. Revisa manualmente:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-monitor --command-id RunShellScript --scripts 'cloud-init status --long'" >&2
      exit 1
    fi
    echo "  ... vm-monitor aun no lista (intento ${tries}/${max_tries}), esperando 15s"
    sleep 15
  done

  echo "== Copiando el bundle a vm-monitor y desplegando (prometheus + blackbox + grafana + node-exporter) =="
  local bundle_b64
  bundle_b64="$(tar -C "${YAMLS_DIR}/generated/monitor" -czf - . | base64 -w0)"
  az vm run-command invoke \
    --resource-group "$RG" --name vm-monitor \
    --command-id RunShellScript \
    --scripts "mkdir -p /opt/monitor && echo '${bundle_b64}' | base64 -d | tar xzf - -C /opt/monitor && \
      mkdir -p /etc/prometheus/targets /etc/node_exporter/textfile && \
      cp /opt/monitor/gen-targets.service /etc/systemd/system/gen-targets.service && \
      cp /opt/monitor/remote/gen-targets.timer /etc/systemd/system/gen-targets.timer && \
      systemctl daemon-reload && systemctl enable --now gen-targets.timer && \
      systemctl start gen-targets.service && \
      cd /opt/monitor && docker compose up -d" \
    --output table

  local vm_ip
  vm_ip="$(az vm list-ip-addresses -g "$RG" -n vm-monitor --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv)"

  echo ""
  echo "== VM de monitoreo desplegada (IP privada: ${vm_ip}) =="
  echo "== Grafana: http://${vm_ip}:3000 (admin / GRAFANA_ADMIN_PASSWORD, ver yamls/generate-monitor.sh) =="
  echo "== Solo alcanzable por el tunel admin de WireGuard (AllowedIPs=10.0.0.0/8 cubre snet-mgmt) =="
  echo "== NO se registra en el DNS interno a proposito: snet-mgmt no se publica (ver docs/plans/internal-dns.md) =="
  echo "== Punto ciego conocido: xss-bot sin sonda propia todavia (ver 'El punto ciego: xss-bot' en el plan) =="
}

# ---------------------------------------------------------------------------
# Funciones — Gateway WireGuard (snet-wg-gateway, 10.10.0.0/28)
# ---------------------------------------------------------------------------
#
# Validado end-to-end 2026-08-08. Ver docs/plans/wireguard-vpn-gateway.md para detalles.
# Unico punto de entrada al lab: VM con IP publica + WireGuard (UDP 51820). El control de acceso
# real (que puede alcanzar cada peer) NO es un NSG -- es iptables en la propia VM, con una regla
# FORWARD por peer scoped a sus CIDR permitidos y politica DROP por defecto. add-peer.sh.tpl es
# la unica pieza que aplica esa regla; create_wg_peer la resuelve localmente con envsubst y la
# manda completa como un solo string a 'az vm run-command invoke'.

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

  # AllowedIPs del cliente != CIDRs de las reglas FORWARD de arriba: el cliente necesita ademas
  # poder ENVIAR paquetes a WG_GW_TUNNEL_IP (si no, el driver de WireGuard los descarta en el
  # propio cliente, antes de que lleguen al gateway -- ver docs/plans/internal-dns.md
  # "Arquitectura de resolución"). El trafico al propio gateway es INPUT, no FORWARD, así que no
  # necesita una regla iptables nueva -- por eso add-peer.sh.tpl (arriba) sigue recibiendo solo
  # allowed_cidrs, sin el /32 del DNS.
  mkdir -p "$WG_CLIENTS_DIR"
  PEER_NAME="$name" \
    CLIENT_PRIVKEY="$privkey" \
    CLIENT_TUNNEL_IP="$tunnel_ip" \
    CLIENT_DNS="${WG_GW_TUNNEL_IP}, ${LAB_DOMAIN}" \
    SERVER_PUBKEY="$server_pubkey" \
    GATEWAY_PUBLIC_IP="$gw_ip" \
    CLIENT_ALLOWED_IPS="${allowed_cidrs// /, }, ${WG_GW_TUNNEL_IP}/32" \
    LAB_DOMAIN="$LAB_DOMAIN" \
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

  echo "== VM del gateway WireGuard (validado 2026-08-08), ver docs/plans/wireguard-vpn-gateway.md =="
  create_wg_nsg

  echo "== az vm create: vm-wg-gateway (${vm_size}, snet-wg-gateway, CON IP publica, IP privada estatica ${WG_GW_PRIVATE_IP}) =="
  az vm create \
    --resource-group "$RG" \
    --name vm-wg-gateway \
    --image Ubuntu2204 \
    --size "$vm_size" \
    --vnet-name "$VNET" \
    --subnet snet-wg-gateway \
    --private-ip-address "$WG_GW_PRIVATE_IP" \
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

  echo "== Esperando a que dnsmasq quede activo (cloud-init, ver docs/plans/internal-dns.md) =="
  tries=0
  until az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway \
          --command-id RunShellScript --scripts "systemctl is-active dnsmasq" \
          --query "value[0].message" --output tsv 2>/dev/null | grep -q "^active$"; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] dnsmasq no quedó activo tras $((max_tries * 15 / 60)) min. Revisa manualmente:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-wg-gateway --command-id RunShellScript --scripts 'systemctl status dnsmasq; journalctl -u dnsmasq --no-pager -n 50'" >&2
      exit 1
    fi
    echo "  ... dnsmasq aún no activo (intento ${tries}/${max_tries}), esperando 15s"
    sleep 15
  done

  local gw_ip
  gw_ip="$(az vm list-ip-addresses --resource-group "$RG" --name vm-wg-gateway \
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)"
  echo "IP publica del gateway: ${gw_ip}"

  echo "== Creando peer admin =="
  create_wg_peer "admin" "10.200.0.2/32" "10.0.0.0/8"

  # Un gateway recreado (VM perdida/reboot con re-imagen) recupera la zona sin pasos manuales --
  # la fuente de verdad local (yamls/generated/dns/*.hosts) ya existe si veniamos de un lab con
  # equipos desplegados.
  sync_lab_dns

  echo ""
  echo "== Gateway WireGuard desplegado. Cliente admin: ${WG_CLIENTS_DIR}/admin.conf =="
  echo "== DNS interno: ${WG_GW_PRIVATE_IP} (VNet) / ${WG_GW_TUNNEL_IP} (tunel) -- ver docs/plans/internal-dns.md =="
  echo "== Validado end-to-end 2026-08-08 (ver docs/plans/wireguard-vpn-gateway.md) =="
}

# ---------------------------------------------------------------------------
# Funciones — DNS interno del lab (dnsmasq en vm-wg-gateway)
# ---------------------------------------------------------------------------
#
# Ver docs/plans/internal-dns.md. Regla general: TODA escritura sobre vm-wg-gateway va en un paso
# secuencial -- 'az vm run-command invoke' es de un solo hilo por VM (misma causa raiz que ya
# obligo a dejar los peers WireGuard secuenciales en add_team_range()). sync_lab_dns() por eso
# manda UN solo push por operacion (concatena todos los *.hosts locales), nunca uno por equipo.

# lab_dns_server() -- devuelve WG_GW_PRIVATE_IP si vm-wg-gateway existe, cadena vacia si no. Es lo
# que decide si las plantillas de contenedor llevan dnsConfig (ver generate-team.sh/generate-dmz.sh).
lab_dns_server() {
  if az vm show --resource-group "$RG" --name vm-wg-gateway --output none 2>/dev/null; then
    echo "$WG_GW_PRIVATE_IP"
  else
    echo ""
  fi
}

# sync_lab_dns -- concatena yamls/generated/dns/*.hosts en una sola zona y la empuja al gateway en
# UNA invocacion de run-command (O(1), no O(N) equipos -- ver "Escalabilidad" en el plan).
# Guardada y no bloqueante, mismo espiritu que create_wg_team_peer: si el gateway no existe, avisa
# y sigue -- un lab sin gateway tiene que poder seguir desplegandose igual.
sync_lab_dns() {
  if ! az vm show --resource-group "$RG" --name vm-wg-gateway --output none 2>/dev/null; then
    echo "[WARN] vm-wg-gateway no existe -- se omite sync_lab_dns (sin gateway no hay DNS que sincronizar)."
    return 0
  fi

  mkdir -p "$DNS_DIR"
  local lockfile="${DNS_DIR}/.lock" zonefile="${DNS_DIR}/lab.hosts"
  (
    flock -x 200
    : > "$zonefile"
    local f
    for f in "${DNS_DIR}"/*.hosts; do
      [[ -e "$f" && "$(basename "$f")" != "lab.hosts" ]] || continue
      cat "$f" >> "$zonefile"
    done
  ) 200>"$lockfile"

  if [[ ! -s "$zonefile" ]]; then
    echo "[WARN] no hay registros DNS locales que sincronizar todavia (yamls/generated/dns/*.hosts vacio)."
    return 0
  fi

  echo "== sync_lab_dns: empujando $(grep -vcE '^\s*(#.*)?$' "$zonefile" || true) registros a vm-wg-gateway (1 invocacion) =="
  local rendered out
  rendered="$(ZONE_NAME="lab" ZONE_B64="$(base64 -w0 "$zonefile")" \
    envsubst '${ZONE_NAME} ${ZONE_B64}' < "${YAMLS_DIR}/wg-gateway/remote/apply-dns.sh.tpl")"

  out="$(az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway \
    --command-id RunShellScript --scripts "$rendered" \
    --query "value[0].message" --output tsv)"
  sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' <<<"$out"

  if ! grep -q '^OK registros=' <<<"$out"; then
    echo "[ERROR] sync_lab_dns: el gateway no confirmo la instalacion. Salida cruda:" >&2
    echo "$out" >&2
    exit 1
  fi
}

# rebuild_lab_dns_from_azure -- reconstruye TODOS los *.hosts desde el estado real de Azure (una
# sola az container list) y los empuja. Comando de reparacion (dns-sync --from-azure) y el que se
# corre antes del evento para garantizar que la zona refleja Azure, no la memoria del operador.
rebuild_lab_dns_from_azure() {
  echo "== Reconstruyendo la zona DNS completa desde Azure (dns-sync --from-azure) =="
  RESOURCE_GROUP="$RG" LAB_DOMAIN="$LAB_DOMAIN" WG_GW_TUNNEL_IP="$WG_GW_TUNNEL_IP" \
    "${YAMLS_DIR}/generate-dns-hosts.sh" all-from-azure
  sync_lab_dns
}

# dns_check <fqdn> -- resuelve <fqdn> preguntando al gateway y lo compara con la IP real que tiene
# Azure para el container group/VM correspondiente (deriva el nombre del container group del FQDN
# via la regla de derivacion inversa). Es el chequeo que se corre antes de abrir el evento.
dns_check() {
  local fqdn="${1:?Uso: $0 dns-check <fqdn.sabanacorp.internal>}"

  if ! az vm show --resource-group "$RG" --name vm-wg-gateway --output none 2>/dev/null; then
    echo "[ERROR] vm-wg-gateway no existe -- no hay DNS que consultar."
    exit 1
  fi

  local resolved
  resolved="$(az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway \
    --command-id RunShellScript --scripts "dig +short @127.0.0.1 ${fqdn}" \
    --query "value[0].message" --output tsv 2>/dev/null \
    | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' | tr -d '\r' | head -n1)"

  if [[ -z "$resolved" ]]; then
    echo "[FALLO] ${fqdn} no resuelve desde el gateway."
    exit 1
  fi

  echo "${fqdn} -> ${resolved} (segun el gateway)"

  # Comparacion best-effort contra Azure: solo para nombres team<N>.<svc> o dmz.<svc>, que son los
  # que este script sabe derivar. Otros FQDN (alias narrativos, infra) solo se resuelven, sin
  # comparar.
  local svc team real_ip cg_name=""
  if [[ "$fqdn" =~ ^([a-z0-9-]+)\.team([0-9]+)\.${LAB_DOMAIN//./\\.}$ ]]; then
    svc="${BASH_REMATCH[1]}"; team="${BASH_REMATCH[2]}"
    cg_name="team${team}-${svc}"
  elif [[ "$fqdn" =~ ^([a-z0-9-]+)\.dmz\.${LAB_DOMAIN//./\\.}$ ]]; then
    svc="${BASH_REMATCH[1]}"
    cg_name="dmz-${svc}"
  fi

  if [[ -n "$cg_name" ]]; then
    real_ip="$(az container show --resource-group "$RG" --name "$cg_name" \
      --query ipAddress.ip --output tsv 2>/dev/null || true)"
    if [[ -n "$real_ip" ]]; then
      if [[ "$real_ip" == "$resolved" ]]; then
        echo "OK: coincide con la IP real de Azure (${cg_name})."
      else
        echo "[DESAJUSTE] Azure tiene ${cg_name}=${real_ip}, pero el DNS resuelve ${resolved}. Corre: $0 dns-sync --from-azure"
        exit 1
      fi
    fi
  fi
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

  if az vm show --resource-group "$RG" --name vm-ctfd --output none 2>/dev/null; then
    local ctfd_power ctfd_ip
    ctfd_power="$(az vm get-instance-view --resource-group "$RG" --name vm-ctfd \
      --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" --output tsv)"
    ctfd_ip="$(az vm list-ip-addresses --resource-group "$RG" --name vm-ctfd \
      --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv)"
    printf "  %-22s %-18s %s\n" "vm-ctfd" "$ctfd_power" "$ctfd_ip"
    if [[ "$ctfd_power" == "VM running" ]]; then
      echo "  docker compose (nginx + ctfd + db + cache):"
      az vm run-command invoke --resource-group "$RG" --name vm-ctfd --command-id RunShellScript \
        --scripts "docker compose -f /opt/ctfd/docker-compose.yml ps --format 'table {{.Name}}\t{{.Status}}'" \
        --query "value[0].message" --output tsv 2>/dev/null \
        | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' | sed 's/^/    /'
    fi
  else
    echo "  vm-ctfd no existe (correr: ./lab-azure.sh deploy-ctfd-vm)"
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
      echo "  wg show wg0 (peers / tunnel IPs / ultimo handshake) + estado DNS interno:"
      # Una sola invocacion de run-command para las dos cosas (ver docs/plans/internal-dns.md
      # "Mecanismo de escritura de la zona": run-command es de un solo hilo por VM, no vale la
      # pena gastar dos round-trips en un status que se corre a menudo).
      az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway --command-id RunShellScript \
        --scripts "wg show wg0; echo '--- dns ---'; systemctl is-active dnsmasq; wc -l /etc/dnsmasq.hosts.d/* 2>/dev/null" \
        --query "value[0].message" --output tsv 2>/dev/null \
        | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' | sed 's/^/    /'
    fi
  else
    echo "  vm-wg-gateway no existe (correr: ./lab-azure.sh deploy-wg-gateway)"
  fi

  echo ""
  echo "== Equipos (snet-teamN) =="
  print_container_states "team"

  echo ""
  echo "== Monitoreo (snet-mgmt) =="
  if az vm show --resource-group "$RG" --name vm-monitor --output none 2>/dev/null; then
    local mon_power mon_ip
    mon_power="$(az vm get-instance-view --resource-group "$RG" --name vm-monitor \
      --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" --output tsv)"
    mon_ip="$(az vm list-ip-addresses --resource-group "$RG" --name vm-monitor \
      --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv)"
    printf "  %-22s %-18s %s\n" "vm-monitor" "$mon_power" "$mon_ip"
    if [[ "$mon_power" == "VM running" ]]; then
      echo "  docker compose (prometheus + blackbox + grafana + node-exporter):"
      az vm run-command invoke --resource-group "$RG" --name vm-monitor --command-id RunShellScript \
        --scripts "docker compose -f /opt/monitor/docker-compose.yml ps --format 'table {{.Name}}\t{{.Status}}'" \
        --query "value[0].message" --output tsv 2>/dev/null \
        | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' | sed 's/^/    /'
      echo "  Grafana: http://${mon_ip}:3000 (tunel admin de WireGuard)"
    fi
  else
    echo "  vm-monitor no existe (correr: ./lab-azure.sh deploy-monitor-vm)"
  fi
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
  deploy-ctfd-vm)    create_ctfd_vm ;;
  deploy-monitor-vm) create_monitor_vm ;;
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
  dns-sync)
    # Sin --from-azure: push O(1) del estado local (yamls/generated/dns/*.hosts) -- rapido, para
    # correr despues de una operacion manual. Con --from-azure: reconstruye todo desde Azure
    # primero (comando de reparacion / chequeo pre-evento). Ver docs/plans/internal-dns.md.
    shift
    if [[ "${1:-}" == "--from-azure" ]]; then
      rebuild_lab_dns_from_azure
    else
      sync_lab_dns
    fi
    ;;
  dns-check)
    shift
    dns_check "${1:-}"
    ;;
  test)              shift; test_deploy "${1:-1}" ;;
  status)            status ;;
  down)              down ;;
  *)
    echo "Uso: $0 {up|deploy-dmz|add-team <N>|add-team-range <inicio> <fin> [paralelismo]|deploy-wiki-vm|deploy-ctfd-vm|deploy-monitor-vm|deploy-wg-gateway|wg-team-peer <N>|dns-sync [--from-azure]|dns-check <fqdn>|test [N]|status|down}"
    exit 1
    ;;
esac

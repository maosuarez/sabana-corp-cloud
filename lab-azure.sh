#!/usr/bin/env bash
#
# lab-azure.sh — Azure test environment for Engineering Week CTF
#
# Summary of what was done and validated (2026-08-01/02, test run):
#   1. az CLI installed and verified (Ubuntu/WSL)
#   2. az login -> "Azure for Students" subscription (tenant Universidad de la Sabana)
#   3. Resource Group created
#   4. VNet created with 4 subnets: wg-gateway, dmz-shared, team1, mgmt
#   5. snet-team1 delegated to Microsoft.ContainerInstance/containerGroups
#   6. Provider Microsoft.ContainerInstance registered in subscription
#   7. Container group "team1-edificio" (database + webapp + linux-server + xss-bot)
#      deployed in snet-team1 with private IP 10.60.1.4 -- WORKED, all 4 containers
#      ended up in Running state (verified with az container show / az container logs).
#
# Since then (see yamls/): the monolithic deployment above was replaced by
# 1-YAML-per-container (yamls/templates/*.tpl + yamls/generate-{team,dmz}.sh), so each
# container gets its own private IP. This script now orchestrates those YAMLs instead of generating
# one combined file.
#
# Usage:
#   export DOCKERHUB_USER="your_username"
#   export DOCKERHUB_TOKEN="your_access_token"   # Docker Hub -> Account Settings -> Security -> New Access Token
#   cp yamls/.env.secrets.example yamls/.env.secrets   # first time only, edit actual values
#
#   ./lab-azure.sh up            # creates RG + VNet + base subnets + delegates snet-dmz-shared
#   ./lab-azure.sh deploy-dmz    # deploys 13 shared DMZ containers (without wiki)
#   ./lab-azure.sh deploy-wg-gateway # creates vm-wg-gateway in snet-wg-gateway (public IP,
#                                 # WireGuard UDP 51820) + admin peer -- run before first
#                                 # add-team so teams already have their tunnel.
#                                 # Validated end-to-end 2026-08-08, see
#                                 # docs/plans/wireguard-vpn-gateway.md
#   ./lab-azure.sh add-team 1    # creates snet-team1, deploys its 4 containers and (if gateway
#                                 # already exists) its WireGuard peer + yamls/generated/wg-clients/team1.conf
#   ./lab-azure.sh add-team 2    # same for team2 (repeat for each team)
#   ./lab-azure.sh add-team-range 1 20   # add-team 1..20 sequential, stops on first error
#   ./lab-azure.sh add-team-range 1 20 4 # same but 4 teams at a time (subnets/WG peers still
#                                 # sequential, see add_team_range() for why)
#   ./lab-azure.sh deploy-wiki-vm # creates vm-wiki in snet-dmz-vm and brings up wiki+wiki-db via
#                                 # docker-compose -- validated end-to-end 2026-08-08, see
#                                 # docs/plans/wiki-on-vm.md (VM quota unblocked same day
#                                 # after upgrade to Pay-As-You-Go, 10 vCPUs
#                                 # StandardDsv7Family in eastus2)
#   ./lab-azure.sh deploy-ctfd-vm # creates vm-ctfd in snet-dmz-vm (nginx + ctfd + mariadb + redis via
#                                 # docker-compose) -- F2 of docs/plans/ctfd-deployment.md, requires
#                                 # CTFD_* block in yamls/.env.secrets and the image
#                                 # <DOCKERHUB_USER>/sabana-corp-ctfd already published
#   ./lab-azure.sh deploy-monitor-vm # creates vm-monitor in snet-mgmt (Prometheus + blackbox_exporter
#                                 # + Grafana + node_exporter, no public IP, managed identity
#                                 # Reader over RG) -- F1+F2 of
#                                 # docs/plans/observability-monitoring.md
#   ./lab-azure.sh dns-sync            # pushes LOCAL state (yamls/generated/dns/*.hosts) to
#                                # dnsmasq on vm-wg-gateway in a single invocation (O(1)) -- see
#                                # docs/plans/internal-dns.md
#   ./lab-azure.sh dns-sync --from-azure # rebuilds ENTIRE zone from 'az container list' and
#                                # pushes it -- repair command / pre-event check
#   ./lab-azure.sh dns-check <fqdn>  # resolves <fqdn> from gateway and compares with real IP
#                                # from Azure
#   ./lab-azure.sh secure-teams  # retrofits nsg-teamN onto every snet-teamN already deployed
#                                # (team<->team isolation, step 1 of
#                                # docs/plans/network-segmentation-nsgs.md) -- new teams get it
#                                # automatically via add-team, this is only for teams created
#                                # before this fix
#   ./lab-azure.sh secure-network # full retrofit of all 3 steps of
#                                # docs/plans/network-segmentation-nsgs.md (teams + DMZ + mgmt) --
#                                # new subnets get their NSG automatically going forward, this is
#                                # only for infrastructure created before this fix. Idempotent.
#   ./lab-azure.sh test [N]      # shortcut: up + deploy-dmz + add-team N (N=1 if omitted) -- entire
#                                # lab at once for quick testing (no VPN gateway
#                                # on purpose, see note in deploy_wg_gateway())
#   ./lab-azure.sh status        # lists all container groups in RG (name/state/IP)
#   ./lab-azure.sh down          # destroys EVERYTHING (deletes entire resource group)
#
# Design: everything lives in a single Resource Group, so "down" is a single command.

set -euo pipefail

# ---------------------------------------------------------------------------
# Variables (adjust here if you change names)
# ---------------------------------------------------------------------------
RG="rg-ctf-semana-ingenieria-test"
LOCATION="eastus2"
VNET="vnet-ctf-lab"
WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YAMLS_DIR="${WORKDIR}/yamls"
WG_CLIENTS_DIR="${YAMLS_DIR}/generated/wg-clients"
SUBSCRIPTION_ID=""

# Lab internal DNS (see docs/plans/internal-dns.md). LAB_DOMAIN lives in this single variable on
# purpose -- changing it is an edit here + a dns-sync. WG_GW_PRIVATE_IP/WG_GW_TUNNEL_IP are
# design constants (first is set with --private-ip-address in deploy_wg_gateway, second is set by
# yamls/wg-gateway/cloud-init.yaml) -- don't need to discover them at generation time.
LAB_DOMAIN="${LAB_DOMAIN:-sabanacorp.internal}"
WG_GW_PRIVATE_IP="10.10.0.4"
WG_GW_TUNNEL_IP="10.200.0.1"
DNS_DIR="${YAMLS_DIR}/generated/dns"

# Network segmentation (docs/plans/network-segmentation-nsgs.md). Every snet-teamN lives inside
# TEAM_SUPERNET_CIDR -- used to deny team<->team traffic while leaving DMZ, mgmt and the gateway
# (all outside this range) untouched by the deny rule. DMZ_SHARED/DMZ_VM/MGMT_CIDR are the fixed
# prefixes from create_vnet(), used the same way for steps 2 (DMZ->teams denied) and 3
# (everything->mgmt denied).
TEAM_SUPERNET_CIDR="10.60.0.0/16"
DMZ_SHARED_CIDR="10.50.0.0/24"
DMZ_VM_CIDR="10.51.0.0/24"
MGMT_CIDR="10.99.0.0/24"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------

require_dockerhub_env() {
  : "${DOCKERHUB_USER:?Must export DOCKERHUB_USER}"
  : "${DOCKERHUB_TOKEN:?Must export DOCKERHUB_TOKEN}"
}

get_subscription_id() {
  if [[ -z "$SUBSCRIPTION_ID" ]]; then
    SUBSCRIPTION_ID="$(az account show --query id --output tsv)"
  fi
  echo "$SUBSCRIPTION_ID"
}

# Waits until a container group has an IP assigned. Container groups injected in a
# subnet (VNet integration) are notoriously slow/unstable getting their IP --
# 'az container create' may return before ipAddress.ip is populated. Retries with
# timeout instead of propagating empty value.
wait_for_ip() {
  local name="$1"
  local max_tries=30 tries=0 ip=""
  until [[ -n "$ip" ]] || (( tries >= max_tries )); do
    ip="$(az container show --resource-group "$RG" --name "$name" --query ipAddress.ip --output tsv 2>/dev/null || true)"
    if [[ -z "$ip" ]]; then
      tries=$((tries + 1))
      echo "  ... ${name} no IP yet (attempt ${tries}/${max_tries}), waiting 10s" >&2
      sleep 10
    fi
  done
  if [[ -z "$ip" ]]; then
    echo "[ERROR] ${name}: could not get IP after $((max_tries * 10 / 60)) min. Check:" >&2
    echo "  az container show -g ${RG} -n ${name} --query \"{state:instanceView.state, ip:ipAddress.ip}\" -o table" >&2
    echo "  az container logs -g ${RG} -n ${name}" >&2
    exit 1
  fi
  echo "$ip"
}

# Deploys a container group from a YAML and returns its private IP via stdout (with retries).
# Progress messages go to caller, not here, to avoid contaminating the capture by $(...).
deploy_container() {
  local file="$1"
  local name
  name="$(basename "$file" .yaml)"
  az container create --resource-group "$RG" --file "$file" --output none
  wait_for_ip "$name"
}

# ---------------------------------------------------------------------------
# Functions — base infrastructure
# ---------------------------------------------------------------------------

check_prereqs() {
  echo "== Checking az CLI and session =="
  az version >/dev/null || { echo "az CLI not installed. See: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"; exit 1; }
  az account show >/dev/null 2>&1 || { echo "No active session. Run: az login"; exit 1; }
  az account show --output table
}

create_resource_group() {
  echo "== Step 1/4: Resource Group =="
  az group create --name "$RG" --location "$LOCATION" --output table
}

create_vnet() {
  echo "== Step 2/4: VNet + base subnets =="
  az network vnet create \
    --resource-group "$RG" \
    --name "$VNET" \
    --location "$LOCATION" \
    --address-prefixes 10.0.0.0/8 \
    --subnet-name snet-wg-gateway \
    --subnet-prefixes 10.10.0.0/28 \
    --output none

  az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
    --name snet-dmz-shared --address-prefixes "$DMZ_SHARED_CIDR" --output none
  create_dmz_shared_nsg

  az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
    --name snet-mgmt --address-prefixes "$MGMT_CIDR" --output none
  create_mgmt_nsg

  # Parallel DMZ for services that don't run in ACI (see docs/plans/wiki-on-vm.md): unlike
  # snet-dmz-shared, this is NOT delegated to ACI, so it supports VMs. Here lives vm-wiki
  # (wiki + wiki-db with docker-compose), deployed by './lab-azure.sh deploy-wiki-vm' and
  # validated end-to-end 2026-08-08.
  az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
    --name snet-dmz-vm --address-prefixes "$DMZ_VM_CIDR" --output none
  create_dmz_vm_nsg

  echo "Base subnets created (snet-team<N> created with 'add-team <N>')."
}

# create_dmz_shared_nsg / create_dmz_vm_nsg -- step 2 of docs/plans/network-segmentation-nsgs.md.
# DMZ is intentional attack surface (filesrv/wiki/parking/decoys are meant to be exploited); it
# must not become a pivot beyond the challenge, so it can only initiate towards the other DMZ
# subnet (untouched by these rules, since neither prefix below covers 10.50/10.51) -- never
# towards a team or mgmt. Inbound is deliberately left at Azure's default (fully open): teams and
# mgmt both need to reach DMZ (the actual challenge path, and monitoring probes).
create_dmz_shared_nsg() {
  local nsg="nsg-dmz-shared"
  echo "== NSG '${nsg}': deny outbound to teams/mgmt (DMZ can't pivot beyond itself) =="
  az network nsg create --resource-group "$RG" --name "$nsg" --location "$LOCATION" --output none
  az network nsg rule create --resource-group "$RG" --nsg-name "$nsg" \
    --name deny-teams-outbound --priority 100 --direction Outbound --access Deny --protocol '*' \
    --source-address-prefixes "$DMZ_SHARED_CIDR" --source-port-ranges '*' \
    --destination-address-prefixes "$TEAM_SUPERNET_CIDR" --destination-port-ranges '*' --output none
  az network nsg rule create --resource-group "$RG" --nsg-name "$nsg" \
    --name deny-mgmt-outbound --priority 200 --direction Outbound --access Deny --protocol '*' \
    --source-address-prefixes "$DMZ_SHARED_CIDR" --source-port-ranges '*' \
    --destination-address-prefixes "$MGMT_CIDR" --destination-port-ranges '*' --output none
  az network vnet subnet update --resource-group "$RG" --vnet-name "$VNET" \
    --name snet-dmz-shared --network-security-group "$nsg" --output none
  echo "${nsg} attached to snet-dmz-shared."
}

create_dmz_vm_nsg() {
  local nsg="nsg-dmz-vm"
  echo "== NSG '${nsg}': deny outbound to teams/mgmt (DMZ can't pivot beyond itself) =="
  az network nsg create --resource-group "$RG" --name "$nsg" --location "$LOCATION" --output none
  az network nsg rule create --resource-group "$RG" --nsg-name "$nsg" \
    --name deny-teams-outbound --priority 100 --direction Outbound --access Deny --protocol '*' \
    --source-address-prefixes "$DMZ_VM_CIDR" --source-port-ranges '*' \
    --destination-address-prefixes "$TEAM_SUPERNET_CIDR" --destination-port-ranges '*' --output none
  az network nsg rule create --resource-group "$RG" --nsg-name "$nsg" \
    --name deny-mgmt-outbound --priority 200 --direction Outbound --access Deny --protocol '*' \
    --source-address-prefixes "$DMZ_VM_CIDR" --source-port-ranges '*' \
    --destination-address-prefixes "$MGMT_CIDR" --destination-port-ranges '*' --output none
  az network vnet subnet update --resource-group "$RG" --vnet-name "$VNET" \
    --name snet-dmz-vm --network-security-group "$nsg" --output none
  echo "${nsg} attached to snet-dmz-vm."
}

# create_mgmt_nsg -- step 3 of docs/plans/network-segmentation-nsgs.md. snet-mgmt is the staff
# plane (CTFd/Provisioner/Monitor); nobody (team or DMZ) should be able to initiate a connection
# into it. Single point of enforcement, on mgmt's own inbound, instead of duplicating an
# outbound-deny-to-mgmt rule on every team/DMZ NSG -- a subnet added later is protected
# automatically without needing to remember to touch its own NSG too. Outbound stays at Azure's
# default (fully open): mgmt->everything is allowed (monitoring/admin need broad reach), and
# WireGuard admin-tunnel traffic (source 10.200.0.2, outside both denied ranges) keeps reaching
# Grafana untouched, same as before this rule existed.
create_mgmt_nsg() {
  local nsg="nsg-mgmt"
  echo "== NSG '${nsg}': deny inbound from teams/DMZ (isolated staff plane) =="
  az network nsg create --resource-group "$RG" --name "$nsg" --location "$LOCATION" --output none
  az network nsg rule create --resource-group "$RG" --nsg-name "$nsg" \
    --name deny-teams-inbound --priority 100 --direction Inbound --access Deny --protocol '*' \
    --source-address-prefixes "$TEAM_SUPERNET_CIDR" --source-port-ranges '*' \
    --destination-address-prefixes "$MGMT_CIDR" --destination-port-ranges '*' --output none
  az network nsg rule create --resource-group "$RG" --nsg-name "$nsg" \
    --name deny-dmz-inbound --priority 200 --direction Inbound --access Deny --protocol '*' \
    --source-address-prefixes "$DMZ_SHARED_CIDR" "$DMZ_VM_CIDR" --source-port-ranges '*' \
    --destination-address-prefixes "$MGMT_CIDR" --destination-port-ranges '*' --output none
  az network vnet subnet update --resource-group "$RG" --vnet-name "$VNET" \
    --name snet-mgmt --network-security-group "$nsg" --output none
  echo "${nsg} attached to snet-mgmt."
}

register_aci_provider() {
  echo "== Step 3/4: Register Microsoft.ContainerInstance provider =="
  az provider register --namespace Microsoft.ContainerInstance
  echo "Waiting for 'Registered' status (may take 1-2 min)..."
  until [[ "$(az provider show --namespace Microsoft.ContainerInstance --query registrationState --output tsv)" == "Registered" ]]; do
    sleep 5
  done
  echo "Provider registered."
}

delegate_dmz_subnet() {
  echo "== Step 4/4: Delegate snet-dmz-shared to ACI =="
  az network vnet subnet update \
    --resource-group "$RG" \
    --vnet-name "$VNET" \
    --name snet-dmz-shared \
    --delegations Microsoft.ContainerInstance/containerGroups \
    --output none
  echo "snet-dmz-shared delegated."
}

up() {
  check_prereqs
  create_resource_group
  create_vnet
  register_aci_provider
  delegate_dmz_subnet
  echo ""
  echo "== DONE == Base infrastructure created (RG, VNet, subnets, snet-dmz-shared delegated)."
  echo "Next steps:"
  echo "  ./lab-azure.sh deploy-dmz     # deploys shared DMZ services"
  echo "  ./lab-azure.sh deploy-wiki-vm # creates vm-wiki (wiki+wiki-db) in snet-dmz-vm"
  echo "  ./lab-azure.sh add-team 1     # creates snet-team1 and deploys its 4 containers"
}

# ---------------------------------------------------------------------------
# Functions — shared DMZ (snet-dmz-shared, 10.50.0.0/24)
# ---------------------------------------------------------------------------

deploy_dmz() {
  require_dockerhub_env
  echo "== Generating DMZ YAML (yamls/generate-dmz.sh) =="
  RESOURCE_GROUP="$RG" VNET="$VNET" SUBSCRIPTION_ID="$(get_subscription_id)" \
    LAB_DOMAIN="$LAB_DOMAIN" LAB_DNS_SERVER="$(lab_dns_server)" \
    "${YAMLS_DIR}/generate-dmz.sh"

  local gen="${YAMLS_DIR}/generated"

  # Wiki (BookStack + MariaDB) does NOT live here: s6-overlay v3 requires real PID 1, which ACI+VNet
  # doesn't guarantee -- confirmed deterministically (ExitCode 100, CrashLoopBackOff). Runs in
  # vm-wiki with docker-compose via './lab-azure.sh deploy-wiki-vm' (see docs/plans/wiki-on-vm.md).
  # Its ACI templates (dmz-wiki*.yaml.tpl) were deleted: they never deployed.
  local svc
  for svc in dmz-filesrv dmz-parking \
             dmz-decoy-printer dmz-decoy-nas dmz-decoy-legacy-web dmz-decoy-database \
             dmz-decoy-camera dmz-decoy-backup dmz-decoy-admin dmz-decoy-ftp \
             dmz-decoy-monitor dmz-decoy-git dmz-decoy-mail; do
    echo "== Deploying ${svc} =="
    deploy_container "${gen}/${svc}.yaml" >/dev/null
  done

  echo "== Registering DMZ DNS (dmz.hosts + infra.hosts) =="
  RESOURCE_GROUP="$RG" LAB_DOMAIN="$LAB_DOMAIN" WG_GW_TUNNEL_IP="$WG_GW_TUNNEL_IP" \
    "${YAMLS_DIR}/generate-dns-hosts.sh" dmz
  sync_lab_dns

  echo ""
  echo "== DMZ deployed: 13 containers, each with its own IP in snet-dmz-shared =="
  echo "== wiki still pending: ./lab-azure.sh deploy-wiki-vm (VM in snet-dmz-vm) =="
  status
}

# ---------------------------------------------------------------------------
# Functions — teams (snet-teamN, 10.60.N.0/24)
# ---------------------------------------------------------------------------

add_team_subnet() {
  local team="$1"
  local prefix="10.60.${team}.0/24"
  echo "== Creating snet-team${team} (${prefix}) =="
  az network vnet subnet create --resource-group "$RG" --vnet-name "$VNET" \
    --name "snet-team${team}" --address-prefixes "$prefix" --output none
  az network vnet subnet update --resource-group "$RG" --vnet-name "$VNET" \
    --name "snet-team${team}" --delegations Microsoft.ContainerInstance/containerGroups --output none
  create_team_nsg "$team"
  echo "snet-team${team} created and delegated."
}

# create_team_nsg <N> -- one NSG per team (docs/plans/network-segmentation-nsgs.md), attached
# directly to snet-teamN (Azure allows this on ACI-delegated subnets). Allows the team's own
# /24 (intra-team traffic: database<->webapp<->xss-bot<->linux-server) at a lower priority
# number (evaluated first), then denies the rest of TEAM_SUPERNET_CIDR -- so another team's /24
# is blocked but DMZ/mgmt/gateway (outside that /16) fall through to the untouched
# AllowVnetOutBound/AllowVnetInBound default rules. `az network nsg create`/`nsg rule create` are
# idempotent PUT operations -- safe to re-run against an already-secured team.
create_team_nsg() {
  local team="$1"
  local own_prefix="10.60.${team}.0/24"
  local nsg="nsg-team${team}"

  echo "== NSG '${nsg}': allow own subnet, deny rest of ${TEAM_SUPERNET_CIDR} (team isolation) =="
  az network nsg create --resource-group "$RG" --name "$nsg" --location "$LOCATION" --output none

  az network nsg rule create --resource-group "$RG" --nsg-name "$nsg" \
    --name allow-own-team-outbound --priority 100 --direction Outbound --access Allow --protocol '*' \
    --source-address-prefixes "$own_prefix" --source-port-ranges '*' \
    --destination-address-prefixes "$own_prefix" --destination-port-ranges '*' --output none
  az network nsg rule create --resource-group "$RG" --nsg-name "$nsg" \
    --name deny-other-teams-outbound --priority 200 --direction Outbound --access Deny --protocol '*' \
    --source-address-prefixes "$own_prefix" --source-port-ranges '*' \
    --destination-address-prefixes "$TEAM_SUPERNET_CIDR" --destination-port-ranges '*' --output none

  az network nsg rule create --resource-group "$RG" --nsg-name "$nsg" \
    --name allow-own-team-inbound --priority 100 --direction Inbound --access Allow --protocol '*' \
    --source-address-prefixes "$own_prefix" --source-port-ranges '*' \
    --destination-address-prefixes "$own_prefix" --destination-port-ranges '*' --output none
  az network nsg rule create --resource-group "$RG" --nsg-name "$nsg" \
    --name deny-other-teams-inbound --priority 200 --direction Inbound --access Deny --protocol '*' \
    --source-address-prefixes "$TEAM_SUPERNET_CIDR" --source-port-ranges '*' \
    --destination-address-prefixes "$own_prefix" --destination-port-ranges '*' --output none

  az network vnet subnet update --resource-group "$RG" --vnet-name "$VNET" \
    --name "snet-team${team}" --network-security-group "$nsg" --output none
  echo "${nsg} attached to snet-team${team}."
}

# secure-teams -- retrofits NSGs onto every snet-teamN that already exists (created before this
# fix). New teams get create_team_nsg automatically via add_team_subnet; this is the one-shot
# repair for teams deployed before it existed.
secure_teams() {
  local teams
  teams="$(az network vnet subnet list --resource-group "$RG" --vnet-name "$VNET" \
    --query "[?starts_with(name,'snet-team')].name" --output tsv | sed 's/^snet-team//')"
  if [[ -z "$teams" ]]; then
    echo "No snet-teamN subnets found."
    return 0
  fi
  local team
  for team in $teams; do
    create_team_nsg "$team"
  done
}

# secure_network -- full retrofit of docs/plans/network-segmentation-nsgs.md (all 3 steps) onto
# subnets that already exist. New subnets get their NSG automatically (create_vnet for
# dmz-shared/dmz-vm/mgmt, add_team_subnet for teams); this is only for infrastructure created
# before this plan existed. Safe to re-run any time -- every create_*_nsg is an idempotent PUT.
secure_network() {
  secure_teams
  if az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name snet-dmz-shared --output none 2>/dev/null; then
    create_dmz_shared_nsg
  else
    echo "snet-dmz-shared doesn't exist yet, skipping."
  fi
  if az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name snet-dmz-vm --output none 2>/dev/null; then
    create_dmz_vm_nsg
  else
    echo "snet-dmz-vm doesn't exist yet, skipping."
  fi
  if az network vnet subnet show --resource-group "$RG" --vnet-name "$VNET" --name snet-mgmt --output none 2>/dev/null; then
    create_mgmt_nsg
  else
    echo "snet-mgmt doesn't exist yet, skipping."
  fi
}

validate_team_num() {
  case "$1" in
    ''|*[!0-9]*) echo "[ERROR] invalid team number: '${1:-}' (e.g., 1, 2, 20)."; exit 1 ;;
  esac
}

require_team_prereqs() {
  require_dockerhub_env
  [[ -f "${YAMLS_DIR}/.env.secrets" ]] || {
    echo "[ERROR] missing ${YAMLS_DIR}/.env.secrets (copy .env.secrets.example and fill in actual values)."
    exit 1
  }
}

# Generates and deploys 4 containers for a team (no subnet, no WireGuard peer, no
# status) -- separated from deploy_team() so it can run in parallel between teams in
# add_team_range() with concurrency > 1. The database->webapp->xss-bot chain (each needs
# the previous IP) remains sequential WITHIN a team; what's parallelized is between
# teams, which are completely independent.
deploy_team_workload() {
  local team="$1"

  echo "== Generating YAML for team${team} (yamls/generate-team.sh) =="
  RESOURCE_GROUP="$RG" VNET="$VNET" SUBSCRIPTION_ID="$(get_subscription_id)" \
    LAB_DOMAIN="$LAB_DOMAIN" LAB_DNS_SERVER="$(lab_dns_server)" \
    "${YAMLS_DIR}/generate-team.sh" "$team"

  local gen="${YAMLS_DIR}/generated"

  echo "== Deploying team${team}-database =="
  local db_ip
  db_ip="$(deploy_container "${gen}/team${team}-database.yaml")"
  echo "team${team}-database IP: ${db_ip}"
  sed -i "s|<DATABASE_IP>|${db_ip}|" "${gen}/team${team}-webapp.yaml"

  echo "== Deploying team${team}-webapp =="
  local webapp_ip
  webapp_ip="$(deploy_container "${gen}/team${team}-webapp.yaml")"
  echo "team${team}-webapp IP: ${webapp_ip}"
  sed -i "s|<WEBAPP_IP>|${webapp_ip}|" "${gen}/team${team}-xss-bot.yaml"

  echo "== Deploying team${team}-xss-bot =="
  local bot_ip
  bot_ip="$(deploy_container "${gen}/team${team}-xss-bot.yaml")"

  echo "== Deploying team${team}-linux-server =="
  local linux_ip
  linux_ip="$(deploy_container "${gen}/team${team}-linux-server.yaml")"

  # DNS: LOCAL write only here (yamls/generated/dns/team<N>.hosts) -- no run-command.
  # This keeps this function safe to run in parallel between teams in
  # add_team_range(); the push to gateway (O(1), not per-team) goes in a separate sequential step
  # (see sync_lab_dns and "Zone write mechanism" in docs/plans/internal-dns.md).
  RESOURCE_GROUP="$RG" LAB_DOMAIN="$LAB_DOMAIN" WG_GW_TUNNEL_IP="$WG_GW_TUNNEL_IP" \
    "${YAMLS_DIR}/generate-dns-hosts.sh" team "$team" "$db_ip" "$webapp_ip" "$linux_ip" "$bot_ip"

  echo "== team${team} deployed: 4 containers, each with its own IP in snet-team${team} =="
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

  case "$start" in ''|*[!0-9]*) echo "[ERROR] usage: $0 add-team-range <start> <end> [concurrency] (e.g., 1 20 4)."; exit 1 ;; esac
  case "$end" in ''|*[!0-9]*) echo "[ERROR] usage: $0 add-team-range <start> <end> [concurrency] (e.g., 1 20 4)."; exit 1 ;; esac
  case "$concurrency" in ''|*[!0-9]*|0) echo "[ERROR] <concurrency> must be an integer >= 1."; exit 1 ;; esac
  if (( start > end )); then
    echo "[ERROR] <start> (${start}) cannot be greater than <end> (${end})."
    exit 1
  fi

  if (( concurrency == 1 )); then
    echo "== Deploying teams ${start}..${end} (sequential, stops on first error) =="
    local team
    for (( team = start; team <= end; team++ )); do
      echo ""
      echo "== [$((team - start + 1))/$((end - start + 1))] team${team} =="
      deploy_team "$team"
    done
    echo ""
    echo "== DONE: teams ${start}..${end} deployed =="
    status
    return
  fi

  # Parallel mode: subnets, DNS and WireGuard peers intentionally stay sequential.
  #   - Subnets: concurrent 'az network vnet subnet create' on the SAME VNet often collide
  #     with 409 AnotherOperationInProgress in Azure -- creating all before parallelizing avoids that
  #     race.
  #   - DNS (sync_lab_dns) and WireGuard peers: both run 'az vm run-command invoke' against
  #     vm-wg-gateway, which is SINGLE-THREADED per VM -- concurrent invocations against the same
  #     VM serialize or fail with operation-in-progress conflict. General rule, not just for
  #     peers: ALL writes to vm-wg-gateway go in a sequential step (see
  #     docs/plans/internal-dns.md "Zone write mechanism and parallelism").
  # What DOES parallelize (the slow part: generating YAML + waiting for 4 IPs per team) is
  # deploy_team_workload, with concurrency limit via bash job control.
  require_team_prereqs

  echo "== Deploying teams ${start}..${end} (parallel x${concurrency}) =="
  echo "== Step 1: subnets (sequential, avoids Azure 409 on same VNet) =="
  local team
  for (( team = start; team <= end; team++ )); do
    add_team_subnet "$team"
  done

  echo ""
  echo "== Step 2: containers per team (parallel x${concurrency}) =="
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
    echo "[ERROR] teams that failed: $(sort -n "$failed_file" | xargs)"
    echo "        check their containers and re-run 'add-team <N>' for those only."
    rm -f "$failed_file"
    exit 1
  fi
  rm -f "$failed_file"

  # Step 2.5: ONE DNS push for entire range, not per-team -- O(1), not O(N). Each
  # deploy_team_workload above already wrote its team<N>.hosts locally (without touching gateway);
  # here they're concatenated and pushed in a single run-command invocation. Goes before
  # peers (step 3) because both touch vm-wg-gateway and that VM processes one run-command at a time.
  echo ""
  echo "== Step 2.5: syncing DNS (1 invocation for ${start}..${end}) =="
  sync_lab_dns

  echo ""
  echo "== Step 3: WireGuard peers (sequential, avoids collision on vm-wg-gateway) =="
  for (( team = start; team <= end; team++ )); do
    create_wg_team_peer "$team"
  done

  echo ""
  echo "== DONE: teams ${start}..${end} deployed (parallel x${concurrency}) =="
  status
}

# ---------------------------------------------------------------------------
# Status and destruction
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Functions — wiki VM (snet-dmz-vm, 10.51.0.0/24)
# ---------------------------------------------------------------------------
#
# Validated end-to-end 2026-08-08. See docs/plans/wiki-on-vm.md for details.
# VM quota unblocked after upgrade to Pay-As-You-Go (10 vCPUs StandardDsv7Family).
create_wiki_vm() {
  local vm_size="${WIKI_VM_SIZE:-Standard_D2s_v7}"

  echo "== Wiki VM (validated 2026-08-08), see docs/plans/wiki-on-vm.md =="
  echo "== Generating docker-compose (yamls/generate-wiki-vm.sh) =="
  LAB_DOMAIN="$LAB_DOMAIN" "${YAMLS_DIR}/generate-wiki-vm.sh"

  echo "== az vm create: vm-wiki (${vm_size}, snet-dmz-vm, no public IP) =="
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

  echo "== Waiting for Docker to be ready (cloud-init) =="
  local tries=0 max_tries=30
  until az vm run-command invoke --resource-group "$RG" --name vm-wiki \
          --command-id RunShellScript --scripts "docker version" \
          --query "value[0].message" --output tsv 2>/dev/null | grep -q "Server:"; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] docker not ready after $((max_tries * 15 / 60)) min. Check manually:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-wiki --command-id RunShellScript --scripts 'cloud-init status --long'" >&2
      exit 1
    fi
    echo "  ... docker not ready yet (attempt ${tries}/${max_tries}), waiting 15s"
    sleep 15
  done

  echo "== Copying docker-compose.yml to VM and deploying (wiki + wiki-db) =="
  local compose_b64
  compose_b64="$(base64 -w0 "${YAMLS_DIR}/generated/wiki-vm-docker-compose.yml")"
  az vm run-command invoke \
    --resource-group "$RG" --name vm-wiki \
    --command-id RunShellScript \
    --scripts "mkdir -p /opt/wiki && echo '${compose_b64}' | base64 -d > /opt/wiki/docker-compose.yml && cd /opt/wiki && docker compose up -d" \
    --output table

  local vm_ip
  vm_ip="$(az vm list-ip-addresses -g "$RG" -n vm-wiki --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv)"

  echo "== Registering wiki.dmz in lab DNS =="
  RESOURCE_GROUP="$RG" LAB_DOMAIN="$LAB_DOMAIN" WG_GW_TUNNEL_IP="$WG_GW_TUNNEL_IP" \
    "${YAMLS_DIR}/generate-dns-hosts.sh" dmz
  sync_lab_dns

  echo ""
  echo "== Wiki VM deployed (private IP: ${vm_ip}) — Validated 2026-08-08, see docs/plans/wiki-on-vm.md =="
  echo "  az vm run-command invoke -g ${RG} -n vm-wiki --command-id RunShellScript --scripts 'docker compose -f /opt/wiki/docker-compose.yml ps'"
}

# ---------------------------------------------------------------------------
# Functions — CTFd VM (snet-dmz-vm, shares subnet with vm-wiki)
# ---------------------------------------------------------------------------
#
# F2 of docs/plans/ctfd-deployment.md. Same pattern as create_wiki_vm(): cloud-init installs
# Docker (+ python3-pip here), generated bundle (docker-compose.yml +
# conf/nginx/http.conf + seed/*) is pushed via 'az vm run-command invoke'. Unlike wiki, secrets
# DO come from yamls/.env.secrets (CTFD_* block) -- explicit plan decision, see
# generate-ctfd-vm.sh.
#
# Finally runs, in order, two scripts fresh-vendored from ../sabana-corp-CTFd by
# generate-ctfd-vm.sh -- neither requires the operator to be connected to admin VPN tunnel:
#   1. seed_setup.py -- completes /setup wizard (event name, team mode, admin account)
#      INSIDE the ctfd container ('docker compose exec'), because CTFd blocks ANY
#      request -- including API -- until /setup is done. Doesn't use HTTP/CSRF: writes
#      directly to CTFd models with Flask context.
#   2. seed_challenges.py -- loads challenges/flags against REST API, FROM the VM host
#      (http://localhost), authenticated with CTFD_PRESET_ADMIN_TOKEN (yamls/.env.secrets): CTFd
#      accepts it as an Access Token for an admin created on-the-fly (see PRESET_ADMIN_TOKEN in
#      templates/ctfd-compose.yml.tpl), so no need to generate a token manually via
#      the UI.
create_ctfd_vm() {
  local vm_size="${CTFD_VM_SIZE:-Standard_D2s_v7}"

  echo "== CTFd VM (docs/plans/ctfd-deployment.md, F2) =="
  require_dockerhub_env

  local secrets_file="${YAMLS_DIR}/.env.secrets"
  [[ -f "$secrets_file" ]] || { echo "[ERROR] missing ${secrets_file}."; exit 1; }
  set -a
  # shellcheck disable=SC1090
  source "$secrets_file"
  set +a
  : "${CTFD_PRESET_ADMIN_TOKEN:?Missing CTFD_PRESET_ADMIN_TOKEN in yamls/.env.secrets}"

  echo "== az vm create: vm-ctfd (${vm_size}, snet-dmz-vm, no public IP) =="
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

  # IP is known only now (after 'az vm create'), so bundle is generated AFTER
  # VM creation, not before -- CTFD_VM_IP goes into TRUSTED_HOSTS (see generate-ctfd-vm.sh) so
  # accessing by direct IP (not just by internal DNS FQDN) doesn't return 500. Needed because
  # WireGuard split-DNS is unreliable on Linux clients (see docs/plans/internal-dns.md) --
  # found in real validation 2026-08-11, operator on Linux browsed by IP and CTFd rejected it before this fix.
  echo "== Generating bundle (yamls/generate-ctfd-vm.sh) =="
  LAB_DOMAIN="$LAB_DOMAIN" CTFD_VM_IP="$vm_ip" "${YAMLS_DIR}/generate-ctfd-vm.sh"

  echo "== Waiting for Docker + pip to be ready (cloud-init) =="
  local tries=0 max_tries=30
  until az vm run-command invoke --resource-group "$RG" --name vm-ctfd \
          --command-id RunShellScript --scripts "docker version && python3 -m pip --version" \
          --query "value[0].message" --output tsv 2>/dev/null | grep -q "Server:"; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] docker/pip not ready after $((max_tries * 15 / 60)) min. Check manually:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-ctfd --command-id RunShellScript --scripts 'cloud-init status --long'" >&2
      exit 1
    fi
    echo "  ... vm-ctfd not ready yet (attempt ${tries}/${max_tries}), waiting 15s"
    sleep 15
  done

  echo "== Copying bundle to vm-ctfd, installing seed deps and deploying (nginx + ctfd + db + cache) =="
  local bundle_b64
  bundle_b64="$(tar -C "${YAMLS_DIR}/generated/ctfd" -czf - . | base64 -w0)"
  az vm run-command invoke \
    --resource-group "$RG" --name vm-ctfd \
    --command-id RunShellScript \
    --scripts "mkdir -p /opt/ctfd && echo '${bundle_b64}' | base64 -d | tar xzf - -C /opt/ctfd && \
      pip3 install -q -r /opt/ctfd/seed/requirements.txt && \
      cd /opt/ctfd && docker compose up -d" \
    --output table

  echo "== Registering ctfd.dmz in lab DNS =="
  RESOURCE_GROUP="$RG" LAB_DOMAIN="$LAB_DOMAIN" WG_GW_TUNNEL_IP="$WG_GW_TUNNEL_IP" \
    "${YAMLS_DIR}/generate-dns-hosts.sh" dmz
  sync_lab_dns

  # 'az vm run-command invoke' returns exit 0 and "ProvisioningState/succeeded" EVEN IF the remote script
  # exits with a non-zero code -- the real result only lives in the text of
  # value[0].message (blocks [stdout]/[stderr]). Found in first real run
  # (2026-08-11): a failing curl -f and seed_challenges.py with traceback both passed
  # unnoticed because code below relied on 'az' exit code or used
  # '--output table' without inspecting the message. From now on: capture message,
  # always print it (no silent '--output table') and decide success/error by its
  # content, not by $?.

  echo "== Waiting for CTFd to respond on localhost (inside vm-ctfd) =="
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
      echo "[ERROR] CTFd did not respond (last HTTP code: '${http_code:-no response}') after $((max_tries * 15 / 60)) min. Check manually:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-ctfd --command-id RunShellScript --scripts 'docker compose -f /opt/ctfd/docker-compose.yml logs --tail 100'" >&2
      exit 1
    fi
    echo "  ... ctfd not responding yet (code '${http_code:-no response}', attempt ${tries}/${max_tries}), waiting 15s"
    sleep 15
  done

  echo "== Completing /setup (seed_setup.py, runs inside ctfd container via 'docker compose exec') =="
  local setup_msg
  setup_msg="$(az vm run-command invoke \
    --resource-group "$RG" --name vm-ctfd \
    --command-id RunShellScript \
    --scripts "cd /opt/ctfd && docker compose exec -T ctfd python3 - < seed/seed_setup.py" \
    --query "value[0].message" --output tsv 2>/dev/null)"
  echo "$setup_msg"
  if ! grep -qE "CTFd (is already )?configured" <<<"$setup_msg"; then
    echo "[ERROR] seed_setup.py did not confirm success (see message above)." >&2
    exit 1
  fi

  echo "== Loading challenges/flags (seed_challenges.py, vendored from sabana-corp-CTFd) =="
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
    echo "[ERROR] seed_challenges.py did not confirm success (see message above)." >&2
    exit 1
  fi

  echo ""
  echo "== CTFd VM deployed (private IP: ${vm_ip}) — see docs/plans/ctfd-deployment.md (F2) =="
  echo "  http://${vm_ip} or http://ctfd.dmz.${LAB_DOMAIN} (via VPN tunnel)"
  echo "  admin: ${CTFD_PRESET_ADMIN_EMAIL} / (password in yamls/.env.secrets, CTFD_PRESET_ADMIN_PASSWORD)"
  if [[ -n "$publish_flag" ]]; then
    echo "  Challenges loaded and PUBLISHED (CTFD_SEED_PUBLISH=1)."
  else
    echo "  Challenges loaded HIDDEN -- run with CTFD_SEED_PUBLISH=1 to publish them, or from UI."
  fi
  echo "  az vm run-command invoke -g ${RG} -n vm-ctfd --command-id RunShellScript --scripts 'docker compose -f /opt/ctfd/docker-compose.yml ps'"
}

# ---------------------------------------------------------------------------
# Functions — monitoring VM (snet-mgmt, 10.99.0.0/24)
# ---------------------------------------------------------------------------
#
# F1+F2 of docs/plans/observability-monitoring.md: Prometheus + blackbox_exporter (external probing,
# zero changes to challenge images) + Grafana (dashboard "Team Wall" + Unified alerts without contact points) + node_exporter (own metrics + textfile collector). Same
# pattern as create_wiki_vm(): cloud-init installs Docker (and also Azure CLI here), rest
# is pushed via 'az vm run-command invoke' -- except here it's a complete bundle (tar+base64), not a
# single file, because the stack has more pieces (prometheus.yml, blackbox.yml, Grafana provisioning,
# discovery script).
#
# Managed identity with Reader ONLY over this Resource Group (never over subscription) -- see
# "Risks: the managed identity is the most valuable asset of snet-mgmt" in the plan.
create_monitor_vm() {
  local vm_size="${MONITOR_VM_SIZE:-Standard_D2s_v7}"

  echo "== Monitoring VM (docs/plans/observability-monitoring.md, F1+F2) =="
  echo "== Generating bundle (yamls/generate-monitor.sh) =="
  RESOURCE_GROUP="$RG" "${YAMLS_DIR}/generate-monitor.sh"

  echo "== az vm create: vm-monitor (${vm_size}, snet-mgmt, no public IP, managed identity) =="
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

  echo "== Assigning Reader role (scope: only this Resource Group) to managed identity =="
  local principal_id sub_id tries max_tries
  principal_id="$(az vm identity show --resource-group "$RG" --name vm-monitor --query principalId --output tsv)"
  sub_id="$(get_subscription_id)"
  tries=0; max_tries=10
  # Retry: newly created identity in Entra ID may take a few seconds to propagate
  # before 'role assignment create' recognizes it (transient PrincipalNotFound, not a
  # real permissions error).
  until az role assignment create \
          --assignee-object-id "$principal_id" --assignee-principal-type ServicePrincipal \
          --role Reader --scope "/subscriptions/${sub_id}/resourceGroups/${RG}" \
          --output none 2>/dev/null; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] could not assign Reader role after ${max_tries} attempts." >&2
      exit 1
    fi
    echo "  ... identity not yet propagated (attempt ${tries}/${max_tries}), waiting 10s"
    sleep 10
  done

  echo "== Waiting for Docker + Azure CLI to be ready (cloud-init) =="
  tries=0; max_tries=30
  until az vm run-command invoke --resource-group "$RG" --name vm-monitor \
          --command-id RunShellScript --scripts "docker version && az version" \
          --query "value[0].message" --output tsv 2>/dev/null | grep -q "Server:"; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] docker/az cli not ready after $((max_tries * 15 / 60)) min. Check manually:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-monitor --command-id RunShellScript --scripts 'cloud-init status --long'" >&2
      exit 1
    fi
    echo "  ... vm-monitor not ready yet (attempt ${tries}/${max_tries}), waiting 15s"
    sleep 15
  done

  echo "== Copying bundle to vm-monitor and deploying (prometheus + blackbox + grafana + node-exporter) =="
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
  echo "== Monitoring VM deployed (private IP: ${vm_ip}) =="
  echo "== Grafana: http://${vm_ip}:3000 (admin / GRAFANA_ADMIN_PASSWORD, see yamls/generate-monitor.sh) =="
  echo "== Only reachable via WireGuard admin tunnel (AllowedIPs=10.0.0.0/8 covers snet-mgmt) =="
  echo "== Intentionally NOT registered in internal DNS: snet-mgmt not published (see docs/plans/internal-dns.md) =="
  echo "== Known blind spot: xss-bot without its own probe yet (see 'The blind spot: xss-bot' in plan) =="
}

# ---------------------------------------------------------------------------
# Functions — WireGuard Gateway (snet-wg-gateway, 10.10.0.0/28)
# ---------------------------------------------------------------------------
#
# Validated end-to-end 2026-08-08. See docs/plans/wireguard-vpn-gateway.md for details.
# Only entry point to lab: VM with public IP + WireGuard (UDP 51820). Real access control
# (what each peer can reach) is NOT an NSG -- it's iptables on the VM itself, with a
# FORWARD rule per peer scoped to its allowed CIDRs and DROP policy by default. add-peer.sh.tpl is
# the only piece that applies that rule; create_wg_peer resolves it locally with envsubst and
# sends it complete as a single string to 'az vm run-command invoke'.

create_wg_nsg() {
  echo "== Dedicated NSG for snet-wg-gateway: only inbound UDP 51820 from Internet =="
  az network nsg create --resource-group "$RG" --name nsg-wg-gateway --location "$LOCATION" --output none

  az network nsg rule create \
    --resource-group "$RG" --nsg-name nsg-wg-gateway \
    --name allow-wireguard-inbound \
    --priority 100 --direction Inbound --access Allow --protocol Udp \
    --source-address-prefixes Internet --source-port-ranges '*' \
    --destination-address-prefixes '*' --destination-port-ranges 51820 \
    --output none

  # Azure default rules (DenyAllInBound at priority 65500) already cover everything else --
  # no need for explicit deny rule. This NSG is deliberately more restrictive than
  # VNet default (which allows AllowVnetInBound): snet-wg-gateway is the only subnet that
  # should not trust "anything within the VNet" as source.
  az network vnet subnet update \
    --resource-group "$RG" --vnet-name "$VNET" --name snet-wg-gateway \
    --network-security-group nsg-wg-gateway --output none
}

# create_wg_peer <name> <tunnel_ip/32> <allowed_cidrs_space_separated>
# Shared between admin peer (deploy_wg_gateway) and team peers (create_wg_team_peer).
create_wg_peer() {
  local name="$1" tunnel_ip="$2" allowed_cidrs="$3"

  echo "== WireGuard peer '${name}': generating/applying to vm-wg-gateway (tunnel ${tunnel_ip}) =="

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
    echo "[ERROR] could not extract keys for peer '${name}'. Raw run-command output:" >&2
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

  # Client AllowedIPs != FORWARD rule CIDRs above: client additionally needs
  # to SEND packets to WG_GW_TUNNEL_IP (otherwise WireGuard driver drops them on the
  # client side, before they reach gateway -- see docs/plans/internal-dns.md
  # "Resolution architecture"). Traffic to the gateway itself is INPUT, not FORWARD, so no
  # new iptables rule needed -- that's why add-peer.sh.tpl (above) still only gets
  # allowed_cidrs, without the DNS /32.
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

# Called from deploy_team() at the end. Graceful, non-blocking: if gateway doesn't exist yet,
# team still deploys (4 containers work fine inside VNet) but without VPN tunnel until
# deploy-wg-gateway is run and add-team is repeated.
create_wg_team_peer() {
  local team="$1"
  if ! az vm show --resource-group "$RG" --name vm-wg-gateway --output none 2>/dev/null; then
    echo "[WARN] vm-wg-gateway doesn't exist -- team${team} deployed, but WITHOUT VPN access yet."
    echo "        Run './lab-azure.sh deploy-wg-gateway' then repeat 'add-team ${team}' to generate its peer."
    return 0
  fi
  create_wg_peer "team${team}" "10.200.${team}.2/32" "10.60.${team}.0/24 10.50.0.0/24 10.51.0.0/24"
}

deploy_wg_gateway() {
  local vm_size="${WG_GW_VM_SIZE:-Standard_D2s_v7}"

  echo "== WireGuard gateway VM (validated 2026-08-08), see docs/plans/wireguard-vpn-gateway.md =="
  create_wg_nsg

  echo "== az vm create: vm-wg-gateway (${vm_size}, snet-wg-gateway, WITH public IP, static private IP ${WG_GW_PRIVATE_IP}) =="
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

  echo "== Waiting for wg0 to be active (cloud-init) =="
  local tries=0 max_tries=30
  until az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway \
          --command-id RunShellScript --scripts "systemctl is-active wg-quick@wg0" \
          --query "value[0].message" --output tsv 2>/dev/null | grep -q "^active$"; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] wg0 not active after $((max_tries * 15 / 60)) min. Check manually:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-wg-gateway --command-id RunShellScript --scripts 'cloud-init status --long'" >&2
      exit 1
    fi
    echo "  ... wg0 not active yet (attempt ${tries}/${max_tries}), waiting 15s"
    sleep 15
  done

  echo "== Waiting for dnsmasq to be active (cloud-init, see docs/plans/internal-dns.md) =="
  tries=0
  until az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway \
          --command-id RunShellScript --scripts "systemctl is-active dnsmasq" \
          --query "value[0].message" --output tsv 2>/dev/null | grep -q "^active$"; do
    tries=$((tries + 1))
    if (( tries >= max_tries )); then
      echo "[ERROR] dnsmasq not active after $((max_tries * 15 / 60)) min. Check manually:" >&2
      echo "  az vm run-command invoke -g ${RG} -n vm-wg-gateway --command-id RunShellScript --scripts 'systemctl status dnsmasq; journalctl -u dnsmasq --no-pager -n 50'" >&2
      exit 1
    fi
    echo "  ... dnsmasq not active yet (attempt ${tries}/${max_tries}), waiting 15s"
    sleep 15
  done

  local gw_ip
  gw_ip="$(az vm list-ip-addresses --resource-group "$RG" --name vm-wg-gateway \
    --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)"
  echo "Gateway public IP: ${gw_ip}"

  echo "== Creating admin peer =="
  create_wg_peer "admin" "10.200.0.2/32" "10.0.0.0/8"

  # A recreated gateway (lost VM/reboot with re-imaging) recovers zone without manual steps --
  # local source of truth (yamls/generated/dns/*.hosts) already exists if we had a lab with
  # deployed teams.
  sync_lab_dns

  echo ""
  echo "== WireGuard gateway deployed. Admin client: ${WG_CLIENTS_DIR}/admin.conf =="
  echo "== Internal DNS: ${WG_GW_PRIVATE_IP} (VNet) / ${WG_GW_TUNNEL_IP} (tunnel) -- see docs/plans/internal-dns.md =="
  echo "== Validated end-to-end 2026-08-08 (see docs/plans/wireguard-vpn-gateway.md) =="
}

# ---------------------------------------------------------------------------
# Functions — lab internal DNS (dnsmasq on vm-wg-gateway)
# ---------------------------------------------------------------------------
#
# See docs/plans/internal-dns.md. General rule: ALL writes to vm-wg-gateway go in a sequential step --
# 'az vm run-command invoke' is single-threaded per VM (same root cause that forces
# WireGuard peers sequential in add_team_range()). sync_lab_dns() therefore
# sends ONE push per operation (concatenates all *.hosts locally), never per-team.

# lab_dns_server() -- returns WG_GW_PRIVATE_IP if vm-wg-gateway exists, empty string if not. This is what
# decides if container templates get dnsConfig (see generate-team.sh/generate-dmz.sh).
lab_dns_server() {
  if az vm show --resource-group "$RG" --name vm-wg-gateway --output none 2>/dev/null; then
    echo "$WG_GW_PRIVATE_IP"
  else
    echo ""
  fi
}

# sync_lab_dns -- concatenates yamls/generated/dns/*.hosts into single zone and pushes to gateway in
# ONE run-command invocation (O(1), not O(N) teams -- see "Scalability" in plan).
# Graceful and non-blocking, same spirit as create_wg_team_peer: if gateway doesn't exist, warns
# and continues -- lab without gateway must still be deployable.
sync_lab_dns() {
  if ! az vm show --resource-group "$RG" --name vm-wg-gateway --output none 2>/dev/null; then
    echo "[WARN] vm-wg-gateway doesn't exist -- skipping sync_lab_dns (no gateway means no DNS to sync)."
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
    echo "[WARN] no local DNS records to sync yet (yamls/generated/dns/*.hosts empty)."
    return 0
  fi

  echo "== sync_lab_dns: pushing $(grep -vcE '^\s*(#.*)?$' "$zonefile" || true) records to vm-wg-gateway (1 invocation) =="
  local rendered out
  rendered="$(ZONE_NAME="lab" ZONE_B64="$(base64 -w0 "$zonefile")" \
    envsubst '${ZONE_NAME} ${ZONE_B64}' < "${YAMLS_DIR}/wg-gateway/remote/apply-dns.sh.tpl")"

  out="$(az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway \
    --command-id RunShellScript --scripts "$rendered" \
    --query "value[0].message" --output tsv)"
  sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' <<<"$out"

  if ! grep -q '^OK registros=' <<<"$out"; then
    echo "[ERROR] sync_lab_dns: gateway did not confirm installation. Raw output:" >&2
    echo "$out" >&2
    exit 1
  fi
}

# rebuild_lab_dns_from_azure -- rebuilds ALL *.hosts from actual Azure state (single
# az container list) and pushes them. Repair command (dns-sync --from-azure) and the one to
# run before event to ensure zone reflects Azure, not operator's memory.
rebuild_lab_dns_from_azure() {
  echo "== Rebuilding complete DNS zone from Azure (dns-sync --from-azure) =="
  RESOURCE_GROUP="$RG" LAB_DOMAIN="$LAB_DOMAIN" WG_GW_TUNNEL_IP="$WG_GW_TUNNEL_IP" \
    "${YAMLS_DIR}/generate-dns-hosts.sh" all-from-azure
  sync_lab_dns
}

# dns_check <fqdn> -- resolves <fqdn> by querying the gateway and compares with real IP that
# Azure has for the corresponding container group/VM (derives container group name from FQDN
# via reverse derivation rule). This is the check that runs before opening event.
dns_check() {
  local fqdn="${1:?Usage: $0 dns-check <fqdn.sabanacorp.internal>}"

  if ! az vm show --resource-group "$RG" --name vm-wg-gateway --output none 2>/dev/null; then
    echo "[ERROR] vm-wg-gateway doesn't exist -- no DNS to query."
    exit 1
  fi

  local resolved
  resolved="$(az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway \
    --command-id RunShellScript --scripts "dig +short @127.0.0.1 ${fqdn}" \
    --query "value[0].message" --output tsv 2>/dev/null \
    | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' | tr -d '\r' | head -n1)"

  if [[ -z "$resolved" ]]; then
    echo "[FAIL] ${fqdn} does not resolve from gateway."
    exit 1
  fi

  echo "${fqdn} -> ${resolved} (according to gateway)"

  # Best-effort comparison against Azure: only for team<N>.<svc> or dmz.<svc> names, which this
  # script knows how to derive. Other FQDNs (narrative aliases, infra) resolve only, no comparison.
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
        echo "OK: matches Azure real IP (${cg_name})."
      else
        echo "[MISMATCH] Azure has ${cg_name}=${real_ip}, but DNS resolves ${resolved}. Run: $0 dns-sync --from-azure"
        exit 1
      fi
    fi
  fi
}

# az container list never returns populated instanceView (API/CLI limitation, not our filter)
# -- provisioningState alone isn't enough either, a container group can stay in
# 'Succeeded' with a container in CrashLoopBackOff inside (seen with dmz-wiki on ACI). That's why
# real state must be queried per-container with 'az container show'.
print_container_states() {
  local prefix="$1"
  local names
  names="$(az container list --resource-group "$RG" --query "[?starts_with(name, '${prefix}')].name" --output tsv 2>/dev/null | sort || true)"
  if [[ -z "$names" ]]; then
    echo "  (none deployed yet)"
    return
  fi
  printf "  %-22s %-18s %-15s %s\n" "NAME" "STATE" "IP" "RESTARTS"
  local name
  while IFS=$'\t' read -r cname state ip restarts; do
    printf "  %-22s %-18s %-15s %s\n" "$cname" "${state:-?}" "${ip:-?}" "${restarts:-0}"
  done < <(
    for name in $names; do
      az container show --resource-group "$RG" --name "$name" \
        --query "[[name, instanceView.state, ipAddress.ip, containers[0].instanceView.restartCount]]" \
        --output tsv
    done
  )
}

status() {
  echo "== Shared DMZ (snet-dmz-shared) =="
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
    echo "  vm-wiki doesn't exist (run: ./lab-azure.sh deploy-wiki-vm)"
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
    echo "  vm-ctfd doesn't exist (run: ./lab-azure.sh deploy-ctfd-vm)"
  fi

  echo ""
  echo "== WireGuard Gateway (snet-wg-gateway) =="
  if az vm show --resource-group "$RG" --name vm-wg-gateway --output none 2>/dev/null; then
    local wg_power wg_pub_ip
    wg_power="$(az vm get-instance-view --resource-group "$RG" --name vm-wg-gateway \
      --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus | [0]" --output tsv)"
    wg_pub_ip="$(az vm list-ip-addresses --resource-group "$RG" --name vm-wg-gateway \
      --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)"
    printf "  %-22s %-18s %s\n" "vm-wg-gateway" "$wg_power" "$wg_pub_ip"
    if [[ "$wg_power" == "VM running" ]]; then
      echo "  wg show wg0 (peers / tunnel IPs / last handshake) + internal DNS state:"
      # Single run-command invocation for both (see docs/plans/internal-dns.md
      # "Zone write mechanism": run-command is single-threaded per VM, not worth
      # spending two round-trips on a status that runs often).
      az vm run-command invoke --resource-group "$RG" --name vm-wg-gateway --command-id RunShellScript \
        --scripts "wg show wg0; echo '--- dns ---'; systemctl is-active dnsmasq; wc -l /etc/dnsmasq.hosts.d/* 2>/dev/null" \
        --query "value[0].message" --output tsv 2>/dev/null \
        | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}' | sed 's/^/    /'
    fi
  else
    echo "  vm-wg-gateway doesn't exist (run: ./lab-azure.sh deploy-wg-gateway)"
  fi

  echo ""
  echo "== Teams (snet-teamN) =="
  print_container_states "team"

  echo ""
  echo "== Monitoring (snet-mgmt) =="
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
      echo "  Grafana: http://${mon_ip}:3000 (WireGuard admin tunnel)"
    fi
  else
    echo "  vm-monitor doesn't exist (run: ./lab-azure.sh deploy-monitor-vm)"
  fi
}

test_deploy() {
  local team="${1:-1}"
  echo "== TEST: base infrastructure + complete DMZ + team${team} =="
  up
  deploy_dmz
  deploy_team "$team"
  echo ""
  echo "== TEST DONE: complete DMZ + team${team} deployed =="
  status
}

down() {
  echo "== Destroying EVERYTHING: deleting entire Resource Group =="
  read -p "This deletes '$RG' and EVERYTHING in it. Confirm? (type 'yes'): " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Cancelled."
    exit 0
  fi
  az group delete --name "$RG" --yes --no-wait
  if az group exists --name NetworkWatcherRG --output tsv | grep -qi true; then
    az group delete --name NetworkWatcherRG --yes --no-wait
  fi
  echo "Deletion in progress (--no-wait). Verify with: az group exists --name $RG"
  echo "(and az group exists --name NetworkWatcherRG)"
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
    # Backfill: generates WireGuard peer/tunnel for a team already deployed with add-team
    # BEFORE the gateway existed (create_wg_team_peer skipped with warning at that
    # time). Doesn't recreate team, only VPN part -- idempotent just like add-team.
    shift
    team="${1:-}"
    case "$team" in
      ''|*[!0-9]*) echo "[ERROR] usage: $0 wg-team-peer <team_number> (e.g., 1, 2, 20)."; exit 1 ;;
    esac
    create_wg_team_peer "$team"
    ;;
  dns-sync)
    # Without --from-azure: O(1) push of local state (yamls/generated/dns/*.hosts) -- fast, to
    # run after manual operation. With --from-azure: rebuilds everything from Azure
    # first (repair command / pre-event check). See docs/plans/internal-dns.md.
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
  secure-teams)      secure_teams ;;
  secure-network)    secure_network ;;
  test)              shift; test_deploy "${1:-1}" ;;
  status)            status ;;
  down)              down ;;
  *)
    echo "Usage: $0 {up|deploy-dmz|add-team <N>|add-team-range <start> <end> [concurrency]|deploy-wiki-vm|deploy-ctfd-vm|deploy-monitor-vm|deploy-wg-gateway|wg-team-peer <N>|dns-sync [--from-azure]|dns-check <fqdn>|secure-teams|secure-network|test [N]|status|down}"
    exit 1
    ;;
esac

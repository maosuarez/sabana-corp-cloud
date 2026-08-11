#!/usr/bin/env bash
#
# generate-dns-hosts.sh — genera bloques de zona DNS (formato /etc/hosts) para el dnsmasq de
# vm-wg-gateway, a partir del estado real de Azure o de IPs ya conocidas por el llamador.
#
# Ver docs/plans/internal-dns.md "Esquema de nombres" y "Mecanismo de escritura de la zona".
# No toca la VM -- solo escribe archivos locales en yamls/generated/dns/. lab-azure.sh los
# concatena y los empuja con sync_lab_dns().
#
# Modos:
#   generate-dns-hosts.sh team <N> <ip_db> <ip_webapp> <ip_linux> <ip_bot>
#     Escribe generated/dns/team<N>.hosts. Sin llamadas a Azure -- seguro de correr en paralelo
#     (lo llama deploy_team_workload() con las IPs que ya tiene en la mano).
#   generate-dns-hosts.sh dmz
#     Escribe generated/dns/dmz.hosts (13 contenedores DMZ + wiki en vm-wiki) e infra.hosts
#     (dns./gw. -> WG_GW_TUNNEL_IP). Una llamada a az container list + una a az vm list-ip-addresses.
#   generate-dns-hosts.sh all-from-azure
#     Reconstruye TODOS los team<N>.hosts + dmz.hosts desde una sola az container list, derivando
#     equipo y servicio del nombre del container group. Es el comando de reparación
#     (dns-sync --from-azure).
#
# Variables de entorno usadas: RESOURCE_GROUP, LAB_DOMAIN, WG_GW_TUNNEL_IP.

set -euo pipefail

RESOURCE_GROUP="${RESOURCE_GROUP:-rg-ctf-semana-ingenieria-test}"
LAB_DOMAIN="${LAB_DOMAIN:-sabanacorp.internal}"
WG_GW_TUNNEL_IP="${WG_GW_TUNNEL_IP:-10.200.0.1}"

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTDIR="${WORKDIR}/generated/dns"
mkdir -p "$OUTDIR"

HEADER="# generado por yamls/generate-dns-hosts.sh -- no editar a mano"

# Tabla de alias narrativos de los decoys: clave = sufijo del container group
# (dmz-decoy-<clave>), valor = "<DECOY_NAME_canonico> <alias_de_perfil>". Son decisiones de guion
# del CTF (deben coincidir con DECOY_NAME/DECOY_PROFILE en templates/dmz-decoy-*.yaml.tpl), no
# derivadas mecánicamente.
declare -A DECOY_ALIASES=(
  [printer]="printer-01 printer"
  [nas]="storage-01 nas"
  [legacy-web]="intranet-old legacy-web"
  [database]="database-test database"
  [camera]="camera-lobby camera"
  [backup]="backup-old backup"
  [admin]="admin-console admin"
  [ftp]="ftp-archive ftp"
  [monitor]="monitor-old monitor"
  [git]="git-legacy git"
  [mail]="mail-old mail"
)

# team_hosts_line <servicio> <alias> <ip> <team> -> una linea de zona para un servicio de equipo.
team_hosts_line() {
  local svc="$1" alias="$2" ip="$3" team="$4"
  printf '%-15s %s.team%s.%s %s.team%s.%s\n' "$ip" "$svc" "$team" "$LAB_DOMAIN" "$alias" "$team" "$LAB_DOMAIN"
}

# dmz_hosts_line <nombre_canonico> <alias> <ip> -> una linea de zona para un servicio de DMZ.
dmz_hosts_line() {
  local canon="$1" alias="$2" ip="$3"
  if [[ -n "$alias" ]]; then
    printf '%-15s %s.dmz.%s %s.dmz.%s\n' "$ip" "$canon" "$LAB_DOMAIN" "$alias" "$LAB_DOMAIN"
  else
    printf '%-15s %s.dmz.%s\n' "$ip" "$canon" "$LAB_DOMAIN"
  fi
}

write_team_hosts() {
  local team="$1" ip_db="$2" ip_webapp="$3" ip_linux="$4" ip_bot="$5"
  local out="${OUTDIR}/team${team}.hosts"
  local tmp="${out}.tmp.$$"
  {
    echo "$HEADER"
    team_hosts_line database db "$ip_db" "$team"
    team_hosts_line webapp helpdesk "$ip_webapp" "$team"
    team_hosts_line linux-server pivot "$ip_linux" "$team"
    team_hosts_line xss-bot bot "$ip_bot" "$team"
  } > "$tmp"
  mv "$tmp" "$out"
  echo "generado: $out"
}

case "${1:-}" in
  team)
    team="${2:?Uso: $0 team <N> <ip_db> <ip_webapp> <ip_linux> <ip_bot>}"
    ip_db="${3:?falta ip_db}"
    ip_webapp="${4:?falta ip_webapp}"
    ip_linux="${5:?falta ip_linux}"
    ip_bot="${6:?falta ip_bot}"
    write_team_hosts "$team" "$ip_db" "$ip_webapp" "$ip_linux" "$ip_bot"
    ;;

  dmz)
    dmz_out="${OUTDIR}/dmz.hosts"
    infra_out="${OUTDIR}/infra.hosts"
    dmz_tmp="${dmz_out}.tmp.$$"
    infra_tmp="${infra_out}.tmp.$$"

    {
      echo "$HEADER"

      ip="$(az container list --resource-group "$RESOURCE_GROUP" \
        --query "[?name=='dmz-filesrv'].ipAddress.ip | [0]" --output tsv 2>/dev/null || true)"
      [[ -n "$ip" ]] && dmz_hosts_line filesrv files "$ip"

      ip="$(az container list --resource-group "$RESOURCE_GROUP" \
        --query "[?name=='dmz-parking'].ipAddress.ip | [0]" --output tsv 2>/dev/null || true)"
      [[ -n "$ip" ]] && dmz_hosts_line parking "" "$ip"

      for decoy_key in "${!DECOY_ALIASES[@]}"; do
        ip="$(az container list --resource-group "$RESOURCE_GROUP" \
          --query "[?name=='dmz-decoy-${decoy_key}'].ipAddress.ip | [0]" --output tsv 2>/dev/null || true)"
        [[ -n "$ip" ]] || continue
        read -r canon alias <<<"${DECOY_ALIASES[$decoy_key]}"
        dmz_hosts_line "$canon" "$alias" "$ip"
      done

      wiki_ip="$(az vm list-ip-addresses --resource-group "$RESOURCE_GROUP" --name vm-wiki \
        --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv 2>/dev/null || true)"
      [[ -n "$wiki_ip" ]] && dmz_hosts_line wiki wiki-int "$wiki_ip"

      ctfd_ip="$(az vm list-ip-addresses --resource-group "$RESOURCE_GROUP" --name vm-ctfd \
        --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv 2>/dev/null || true)"
      [[ -n "$ctfd_ip" ]] && dmz_hosts_line ctfd scoreboard "$ctfd_ip"
    } > "$dmz_tmp"
    mv "$dmz_tmp" "$dmz_out"
    echo "generado: $dmz_out"

    {
      echo "$HEADER"
      printf '%-15s dns.%s gw.%s\n' "$WG_GW_TUNNEL_IP" "$LAB_DOMAIN" "$LAB_DOMAIN"
    } > "$infra_tmp"
    mv "$infra_tmp" "$infra_out"
    echo "generado: $infra_out"
    ;;

  all-from-azure)
    echo "== Reconstruyendo zona completa desde az container list =="
    rows="$(az container list --resource-group "$RESOURCE_GROUP" \
      --query "[].{n:name,ip:ipAddress.ip}" --output tsv 2>/dev/null || true)"

    declare -A team_db team_webapp team_linux team_bot
    dmz_tmp="${OUTDIR}/dmz.hosts.tmp.$$"
    echo "$HEADER" > "$dmz_tmp"

    while IFS=$'\t' read -r name ip; do
      [[ -n "$name" && -n "$ip" ]] || continue
      case "$name" in
        team*-database)     t="${name#team}"; t="${t%-database}";     team_db[$t]="$ip" ;;
        team*-webapp)       t="${name#team}"; t="${t%-webapp}";       team_webapp[$t]="$ip" ;;
        team*-linux-server) t="${name#team}"; t="${t%-linux-server}"; team_linux[$t]="$ip" ;;
        team*-xss-bot)      t="${name#team}"; t="${t%-xss-bot}";      team_bot[$t]="$ip" ;;
        dmz-filesrv)        dmz_hosts_line filesrv files "$ip" >> "$dmz_tmp" ;;
        dmz-parking)        dmz_hosts_line parking "" "$ip" >> "$dmz_tmp" ;;
        dmz-decoy-*)
          key="${name#dmz-decoy-}"
          if [[ -n "${DECOY_ALIASES[$key]:-}" ]]; then
            read -r canon alias <<<"${DECOY_ALIASES[$key]}"
            dmz_hosts_line "$canon" "$alias" "$ip" >> "$dmz_tmp"
          fi
          ;;
      esac
    done <<<"$rows"

    wiki_ip="$(az vm list-ip-addresses --resource-group "$RESOURCE_GROUP" --name vm-wiki \
      --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv 2>/dev/null || true)"
    [[ -n "$wiki_ip" ]] && dmz_hosts_line wiki wiki-int "$wiki_ip" >> "$dmz_tmp"

    ctfd_ip="$(az vm list-ip-addresses --resource-group "$RESOURCE_GROUP" --name vm-ctfd \
      --query "[0].virtualMachine.network.privateIpAddresses[0]" --output tsv 2>/dev/null || true)"
    [[ -n "$ctfd_ip" ]] && dmz_hosts_line ctfd scoreboard "$ctfd_ip" >> "$dmz_tmp"
    mv "$dmz_tmp" "${OUTDIR}/dmz.hosts"
    echo "generado: ${OUTDIR}/dmz.hosts"

    for t in "${!team_db[@]}"; do
      write_team_hosts "$t" "${team_db[$t]:-}" "${team_webapp[$t]:-}" "${team_linux[$t]:-}" "${team_bot[$t]:-}"
    done

    infra_tmp="${OUTDIR}/infra.hosts.tmp.$$"
    { echo "$HEADER"; printf '%-15s dns.%s gw.%s\n' "$WG_GW_TUNNEL_IP" "$LAB_DOMAIN" "$LAB_DOMAIN"; } > "$infra_tmp"
    mv "$infra_tmp" "${OUTDIR}/infra.hosts"
    echo "generado: ${OUTDIR}/infra.hosts"
    ;;

  *)
    echo "Uso: $0 {team <N> <ip_db> <ip_webapp> <ip_linux> <ip_bot>|dmz|all-from-azure}"
    exit 1
    ;;
esac

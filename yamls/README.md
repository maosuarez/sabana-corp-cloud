# yamls/

One ACI file (`az container create --file <file>.yaml`) per container. Each gets its own
private IP when deployed — this is how we achieve "all different IPs" instead of grouping
multiple containers in a single container group (which share one IP).

Normal usage: nothing in this folder runs by hand. `../lab-azure.sh` (`deploy-dmz`, `add-team
<N>`) orchestrates generation + deployment + IP resolution between dependent containers. This
folder documents how that orchestration works in case it needs debugging or extending.

## Content

**`templates/team-*.yaml.tpl`** — team-number-agnostic templates (variable `${TEAM}`),
one per service: `database`, `webapp`, `linux-server`, `xss-bot`. Images from
`sabana-corp-network`, subnet `snet-team${TEAM}`.

**`templates/dmz-*.yaml.tpl`** — shared service templates (don't depend on any
team): `filesrv`, `parking`, 11 `decoy-*` — 13 total, all deployed by `deploy-dmz`.
Images are from Docker Hub account `maosuarez` (`sabanacorp-filesrv`,
`sabanacorp-parking`, `sabanacorp-decoy`), built from
`sabana-corp-dmz` content. Fixed subnet `snet-dmz-shared`. **Wiki is not here**: `dmz-wiki.yaml.tpl` and
`dmz-wiki-db.yaml.tpl` existed and were deleted (BookStack doesn't boot on ACI, and generated
without deploying) — today `wiki` + `wiki-db` run in `vm-wiki`, see
`wiki-vm-compose.yml.tpl` below.

**`generate-team.sh <N>`** / **`generate-dmz.sh`** — resolve `${DOCKERHUB_USER}`,
`${DOCKERHUB_TOKEN}`, `${SUBSCRIPTION_ID}`, `${RESOURCE_GROUP}`, `${VNET}` (and `${TEAM}` for
team) into the corresponding templates, writing to `generated/`. `lab-azure.sh` calls them with those
variables already resolved (`RG`, `VNET`, subscription id via `az account show`); only need to
export `DOCKERHUB_USER`/`DOCKERHUB_TOKEN` and have `.env.secrets` ready. Manual invocation only
needed for debugging generation without deploying.

Also resolve `${LAB_DOMAIN}`/`${LAB_DNS_SERVER}` (see "Internal DNS" below) — if
`LAB_DNS_SERVER` comes empty (lab without `vm-wg-gateway` deployed yet, or `./lab-azure.sh test`),
generator deletes the `dnsConfig` block from resulting YAML with `sed` between sentinels
`DNSCONFIG-BEGIN`/`DNSCONFIG-END` — `envsubst` doesn't support conditionals, so that's the
simplest way same template works with and without gateway.

`generated/` is in `.gitignore` (contains resolved secrets) — it's the intermediate output that
`lab-azure.sh` deploys with `az container create --file`, not versioned.

**`templates/wiki-vm-compose.yml.tpl`** / **`generate-wiki-vm.sh`** / **`wiki-vm/cloud-init.yaml`**
— Validated end-to-end 2026-08-08, see `docs/plans/wiki-on-vm.md`. Generate/deploy
(`lab-azure.sh deploy-wiki-vm`) a docker-compose of wiki+wiki-db on a VM in `snet-dmz-vm`,
rather than ACI (workaround for s6-overlay/PID1 problem documented in project memory).
Name resolution between `wiki` and `wiki-db` works natively via Docker
`wiki_backend` network in compose, without needing IP injection.

**`templates/ctfd-compose.yml.tpl`** / **`generate-ctfd-vm.sh`** / **`ctfd-vm/`** — F2 of
`docs/plans/ctfd-deployment.md`, **validated end-to-end against real Azure (2026-08-11)**.
Same pattern as wiki (VM in `snet-dmz-vm`, `lab-azure.sh deploy-ctfd-vm`), complete stack
adapted from `../sabana-corp-CTFd/docker-compose.prod.yml` (nginx + ctfd/gunicorn + MariaDB +
Redis). Unlike wiki, secrets (`SECRET_KEY`, DB credentials, pre-created admin)
DO come from `.env.secrets` (CTFD_* block) — explicit plan decision, see
`generate-ctfd-vm.sh`. Image: `${DOCKERHUB_USER}/sabana-corp-ctfd`, published by
`../sabana-corp-CTFd/.github/workflows/deploy.yml`. First boot without manual clicks:
`create_ctfd_vm()` runs `../sabana-corp-CTFd/scripts/seed_setup.py` (vendored in
`generated/ctfd/seed/`, runs inside `ctfd` container via `docker compose exec`) to
complete `/setup` wizard, and `CTFD_PRESET_ADMIN_TOKEN` (`PRESET_ADMIN_TOKEN` native to CTFd)
replaces the Access Token normally generated manually via UI.

**`.env.secrets`** (gitignored, template in `.env.secrets.example`) — service flags and secrets
**per team**, **shared across all teams**: `add-team 1` and `add-team 2`
produce the same `FLAG_DATABASE`, `FLAG_WEBAPP_XSS`, etc. Only container group name and subnet differ.
Intentional: CTFd validates one flag per challenge for all teams, so loading it once in CTFd works for any instance. Edit `.env.secrets` and
re-run `add-team <N>` updates those values for that team (doesn't re-deploy others
automatically).

DMZ secrets/flags (`dmz-parking`, and wiki ones in `generate-wiki-vm.sh`) stay
embedded as literals in their templates — don't go through `.env.secrets` yet because DMZ is
a single shared deployment, not N copies per team.

Provisioner (mentioned in `snet-dmz-shared` architecture) still has no image/Dockerfile
in any repo. CTFd does have image (`sabana-corp-ctfd`, operator's Docker Hub account) and is
implemented and validated end-to-end against real Azure (see `ctfd-vm/`/`generate-ctfd-vm.sh` above)
— see `docs/plans/ctfd-deployment.md`. Monitor also implemented and validated, see
"Observability" below (lives in `snet-mgmt`, not in `snet-dmz-shared`).

## Observability (Prometheus + Grafana on `vm-monitor`)

F1+F2 implemented and validated against real Azure (2026-08-10) — see
`docs/plans/observability-monitoring.md` for complete design.

- **`monitor/`** — cloud-init (Docker + Azure CLI), `prometheus/prometheus.yml`,
  `blackbox/blackbox.yml` (modules `tcp_connect`/`http_2xx`/`ssh_banner`/`dns_udp`),
  `grafana/provisioning/` (datasource, dashboards "Team Wall"/"DMZ Wall", 7 Unified
  Alerting rules) and `remote/gen_targets.py` (runs on `vm-monitor` every 60s).
- **`templates/monitor-compose.yml.tpl`** / **`templates/monitor-gen-targets.service.tpl`** /
  **`generate-monitor.sh`** — same pattern as `generate-wiki-vm.sh`: resolve templates
  (`GRAFANA_ADMIN_PASSWORD`, `RESOURCE_GROUP`) and copy rest of `monitor/` as-is to
  `generated/monitor/`, which `lab-azure.sh` packages (tar+base64) and pushes to `vm-monitor` in one
  `run-command` invocation (same mechanism as `sync_lab_dns`).
- **`gen_targets.py`** discovers services via `az container list` (single call) and writes
  `aci_targets.json` (Prometheus file_sd) + `sabana_ip_drift`. Control plane state
  (`sabana_container_state`, `sabana_container_restart_count`) needs `az container show` **per
  container** — `az container list` doesn't return populated `instanceView` (same limitation as
  `print_container_states()` in `lab-azure.sh`) — so refreshes every 5 min (not each 60s tick),
  parallelized with bounded pool and cached to disk, to avoid 93 calls/min to control plane.
- **Host paths that must match literally** between `gen_targets.py` and
  `templates/monitor-compose.yml.tpl`: `/etc/prometheus/targets` and `/etc/node_exporter/textfile`.
  Script writes there directly (not to `/opt/monitor/...`) and compose mounts those same
  host paths — mismatch here leaves targets/metrics invisible to containers
  without any command failing (happened once in 2026-08-10 validation, see commit).
- Pending: `BotStuck` (needs health endpoint in `bot.js`, repo `sabana-corp-network`) and
  `GatewayNoHandshakes` (would need more than `Reader` permissions for managed identity). F3
  (`restore team/dmz`) and F4 (logs) not implemented.

## Internal DNS (dnsmasq on `vm-wg-gateway`)

Implemented — see `docs/plans/internal-dns.md` for complete design. Operational summary:

- **`generate-dns-hosts.sh`** — generates zone blocks (format `/etc/hosts`) in `generated/dns/`.
  Three modes: `team <N> <ips...>` (local write, used by `deploy_team_workload` with IPs already
  in hand, no Azure calls — safe in parallel), `dmz` (reads `az container list` +
  `vm-wiki` IP), and `all-from-azure` (rebuilds everything from single `az container list` —
  what `dns-sync --from-azure` runs).
- **`sync_lab_dns()`** (in `lab-azure.sh`) — concatenates all `generated/dns/*.hosts` and
  pushes to gateway in **one** `az vm run-command invoke`
  (`yamls/wg-gateway/remote/apply-dns.sh.tpl`), regardless of team count. Called at
  end of `deploy_dmz`, `deploy_team`, `create_wiki_vm`, and once in `add_team_range` (between
  parallel container step and sequential WireGuard peer step).
- **`./lab-azure.sh dns-sync [--from-azure]`** / **`dns-check <fqdn>`** — manual
  sync and verify commands (compares gateway resolution against real Azure IP).
- Domain: `sabanacorp.internal` (variable `LAB_DOMAIN` in `lab-azure.sh`), **not** `.local` (mDNS
  hijacks those queries on macOS/Linux with avahi).

**Container environment variables stay as IPs on purpose** (`<DATABASE_IP>`,
`<WEBAPP_IP>` — see next section): DNS is a naming layer for humans and navigation
within the CTF, not the data plane for challenges. A down dnsmasq doesn't take down any already-deployed challenge.

## Deployment Order and IP Resolution (what `lab-azure.sh` does for you)

ACI has no DNS between container groups — a YAML can't refer to another by name, so
a container that depends on another needs its real IP. `deploy_team` in `lab-azure.sh` already
does this automatically via `sed` on the generated YAML:

1. `team<N>-database` → read its IP → fill `<DATABASE_IP>` in `team<N>-webapp.yaml` → deploy `team<N>-webapp`
2. `team<N>-webapp` → read its IP → fill `<WEBAPP_IP>` in `team<N>-xss-bot.yaml` → deploy `team<N>-xss-bot`
3. `team<N>-linux-server` — independent

DMZ services (`dmz-filesrv`, `dmz-parking`, 11 `dmz-decoy-*`) deploy in any
order (independent). Wiki (`wiki` + `wiki-db`) is not an ACI container — lives in a VM
in `snet-dmz-vm` with docker-compose (`deploy-wiki-vm`), where name resolution between
services is native via `wiki_backend` network.

If you need to do it by hand (debugging):

```bash
az container show -g rg-ctf-semana-ingenieria-test -n <name> --query ipAddress.ip -o tsv
```

**Why this still matters even with internal DNS above implemented**: DNS resolves
a name to an IP at *query time* (dnsmasq responds with what it knows now); the
`sed` above bakes an IP at *deployment time* (fixed inside container YAML, not queried again).
DNS record for `team7-database` can only exist
*after* Azure assigns it an IP — same as `<DATABASE_IP>` always — so
`wait_for_ip` remains 95% of the time and 100% of fragility in this step. Only thing that would
change if env vars switched to FQDN would move coupling from "deploy time" to "runtime"
(each `webapp` reconnect to MySQL would go through dnsmasq) — evaluated and **intentionally rejected**
in `docs/plans/internal-dns.md` ("The egg and the chicken").

## Pending / Known Gaps

- **Persistence — solved for `filesrv`**: uses own image (`maosuarez/sabanacorp-filesrv`)
  with `file-srv/data` content baked via Dockerfile — no longer depends on docker-compose
  bind mount that ACI doesn't support.
- **Persistence — solved for `wiki` and `wiki-db`**: migrated from ACI to VM with docker-compose
  (`deploy-wiki-vm`). Persistent volumes (`wiki_mariadb_data`, `wiki_bookstack_config`)
  work natively in plain Docker, solving both s6-overlay/PID1 problem and
  BookStack config persistence (validated end-to-end 2026-08-08).
- **CTFd**: implemented and validated end-to-end against real Azure (`deploy-ctfd-vm`, 2026-08-11) —
  see `docs/plans/ctfd-deployment.md`. **Provisioner**: not yet implemented in any repo.
  **Monitor**: implemented and validated, see "Observability" above.
- **VPN connector**: solved. WireGuard gateway implemented and validated end-to-end 2026-08-08
  (see `docs/plans/wireguard-vpn-gateway.md`, commands `deploy-wg-gateway` and `wg-team-peer` in
  `lab-azure.sh`).
- **Access from internal network**: each container already has unique IP within its subnet
  (`snet-dmz-shared` or `snet-team<N>`), but actual team access to DMZ services
  still depends on VNet subnets being routable to each other (peering/routes within
  `vnet-ctf-lab` — Azure already routes between subnets of same VNet by default, but NSGs validation pending if added).
- **Internal DNS**: validated end-to-end 2026-08-10 against real Azure — Phase 0 (assumption checks) and
  Phase 1 (dnsmasq on live VM without recreation) completed, zone synced and round-trip verified.
  Detail in `docs/plans/internal-dns.md`. Caveat: containers pre-2026-08-10 don't have `dnsConfig`
  applied (would need recreation); new deploys get it automatically.
- **`nmap-sabana-corp` (participant reconnaissance tool)**: package implemented
  in `tools/nmap-sabana-corp/` (Node ≥18, ESM, zero runtime dependencies), with unit tests (`node
  --test`) and single-file bundle. `generate-wg-client.sh` already generates `nmap-sabana-corp.mjs`
  alongside each `.conf` in `yamls/generated/wg-clients/`. **Not yet tested against real lab**:
  three Phase 0 plan assumptions (PTR from real tunnel, closed-port behavior on ACI, conntrack pressure
  on gateway) still unverified, and conntrack `sysctl` (Phase 3) not yet applied to `vm-wg-gateway`.
  Also not published to npm or name reserved. See `docs/plans/nmap-sabana-corp.md` for detail and pending test plan.

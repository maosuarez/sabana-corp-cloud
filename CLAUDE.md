# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this

Infrastructure as code for **Sabana Corp**, the CTF for Engineering Week at Universidad de la 
Sabana. Everything runs on Azure Container Instances (ACI) within a VNet with no internet 
egress — access is granted only after breaking through a captive portal and authenticating via VPN.

Current status: `lab-azure.sh` stands up the base infrastructure (RG, VNet, subnets) and 
orchestrates deployment of the shared DMZ, the wiki VM, the WireGuard gateway, and N teams using 
YAML templates from `yamls/`.

**All implementations were validated end-to-end on 2026-08-08**: `up`, `deploy-dmz`, 
`deploy-wiki-vm`, `deploy-wg-gateway`, `add-team`/`add-team-range`, and the complete VPN flow. 
When a code comment says "validated 2026-08-08", it refers to that run. CTFd was validated 
separately on 2026-08-11 (see note below). What is **not** implemented or tested: Provisioner 
(no image in any repo yet). `docs/plans/network-segmentation-nsgs.md` (all 3 steps: team↔team,
DMZ→teams, everything→mgmt) was implemented and validated end-to-end 2026-08-14, starting from a
live lateral-movement finding (see below).
This file updates as design decisions are made.

**CTFd (`docs/plans/ctfd-deployment.md`): F1 implemented on the `../sabana-corp-CTFd` side
(challenge manifest + seed script). F2 — validated end-to-end against real Azure
(2026-08-11)**: `./lab-azure.sh deploy-ctfd-vm` creates `vm-ctfd` in `snet-dmz-vm` (nginx +
ctfd/gunicorn + MariaDB + Redis via docker-compose), completes `/setup`, and loads 5
challenges/flags with zero manual clicks — `PRESET_ADMIN_TOKEN` (`CTFD_PRESET_ADMIN_TOKEN`)
replaces the manually-generated Access Token, and `../sabana-corp-CTFd/scripts/seed_setup.py` 
(runs inside the `ctfd` container, not on the host VM) completes the `/setup` wizard — necessary 
because CTFd blocks all requests, including API, until that wizard finishes. The actual run found 
and fixed two bugs: `TRUSTED_HOSTS` did not include `localhost` (seed scripts hit CTFd there, 
via nginx, and without it Werkzeug returns 500) and `az vm run-command invoke` does not propagate 
the exit code of the remote script (`--output table` can report success for a script that actually 
failed) — any new `run-command` must capture and inspect `value[0].message`, not rely on `az` 
exit codes. Secrets via the `CTFD_*` block in `yamls/.env.secrets` (unlike the wiki, which uses 
literals). Image `${DOCKERHUB_USER}/sabana-corp-ctfd`, published by
`../sabana-corp-CTFd/.github/workflows/deploy.yml`. **Challenges load as `hidden` by
default — `/challenges` appears empty even when logged in as admin until they are published
(`CTFD_SEED_PUBLISH=1` in the deploy, or `seed_challenges.py --publish` without recreating the VM).** 
This is by design, not a bug — exact commands and event-day runbook in "Event-day runbook",
`docs/plans/ctfd-deployment.md`.

**Internal DNS (`docs/plans/internal-dns.md`): validated against real Azure (2026-08-10).** dnsmasq 
on `vm-wg-gateway`, domain `sabanacorp.internal`, commands `dns-sync [--from-azure]` / `dns-check
<fqdn>`. Phase 0 (assumption checks) and Phase 1 (dnsmasq on live VM) complete; full zone
synchronized and validated end-to-end. Caveat: containers deployed before this session
(team1, team2, DMZ) do not yet receive `dnsConfig` (would require recreation); new deployments 
receive it automatically. Full detail in `docs/plans/internal-dns.md`.

**Observability (`docs/plans/observability-monitoring.md`): F1+F2 implemented and validated
against real Azure (2026-08-10).** `./lab-azure.sh deploy-monitor-vm` creates `vm-monitor` in
`snet-mgmt` (Prometheus + blackbox_exporter + Grafana + node_exporter, no public IP, managed
identity with `Reader` role on this Resource Group only). `gen_targets.py` (systemd timer, 60s)
discovers services via `az container list` and generates probe targets (`probe_success` per
team/service) + `sabana_ip_drift`; control plane state (`sabana_container_state`,
`sabana_container_restart_count`) refreshes every 5 min via `az container show` **per
container**, parallelized and cached — correction from the original plan, which assumed
(incorrectly) that `az container list` returned populated `instanceView`; it does not, same
limitation already documented for `print_container_states()` in `lab-azure.sh`. Two dashboards
("Team Dashboard", "DMZ + Infrastructure Dashboard") and 7 of 9 alert rules from the plan
provisioned as code in Grafana Unified Alerting (no contact points). Pending:
`BotHanging` (requires health endpoint in `bot.js`, repo `sabana-corp-network`, outside this
repo) and `GatewayNoHandshakes` (would require raising managed identity scope beyond
`Reader`, not justified yet). F3 (`restore team/dmz`) and F4 (logs) remain unimplemented.
Full detail in `docs/plans/observability-monitoring.md`.

**`nmap-sabana-corp` (`docs/plans/nmap-sabana-corp.md`): package implemented in
`tools/nmap-sabana-corp/`, NOT validated against the real lab.** Network discovery tool
for the participant (Node ≥18, ESM, zero runtime dependencies): scope derived from the active
WireGuard tunnel (or `--conf`/`--cidr`), facts measured via real two-phase TCP connect scan, and
names decorated via PTR against the lab resolver (`10.200.0.1`) — never the reverse. `npm --test`
passes (36 unit tests, no real infrastructure). `generate-wg-client.sh` generates
`nmap-sabana-corp.mjs` (single-file bundle, via `tools/nmap-sabana-corp/scripts/build-bundle.mjs`,
no external bundler) alongside each `.conf` in `yamls/generated/wg-clients/`, and the participant
README (`yamls/templates/wg-client-readme.md.tpl`) already documents it. Publication workflow
(`.github/workflows/nmap-sabana-corp.yml`, tag `nmap-v*`) **has run and published successfully**:
`NPM_TOKEN` was already configured and the package name already reserved (contrary to an earlier,
stale version of this note) — `nmap-v0.1.0-draft` published 2026-08-12, `nmap-v1.0.0` published
2026-08-14, both live on the public npm registry as `nmap-sabana-corp`. Tagging `1.0.0` happened
before Phase 0 validation below was run — a version-number/reality mismatch, not a blocker; treat
Phase 0 as still outstanding regardless of what the version number says. **Pending, explicitly
outside this implementation**: the three Phase 0 assumptions in the plan (PTR from a real tunnel,
closed-port behavior in ACI, conntrack pressure on the gateway with N teams), and the `sysctl`
conntrack tuning on `vm-wg-gateway` (Phase 3). Do not touch `yamls/wg-gateway/cloud-init.yaml`
or the live gateway without re-reading "What breaks first" in the plan first — that is the
real design risk.

## Commands

```bash
export DOCKERHUB_USER="..."
export DOCKERHUB_TOKEN="..."   # Docker Hub -> Account Settings -> Security -> New Access Token
cp yamls/.env.secrets.example yamls/.env.secrets   # first time only; edit actual flags/secrets

./lab-azure.sh up                # RG + VNet + base subnets + delegate snet-dmz-shared to ACI
./lab-azure.sh deploy-dmz        # deploy 13 shared DMZ containers (wiki separate, see below)
./lab-azure.sh deploy-wiki-vm    # create vm-wiki (wiki+wiki-db via docker-compose) in snet-dmz-vm
./lab-azure.sh deploy-wg-gateway # create vm-wg-gateway (WireGuard, public IP) + admin tunnel in snet-wg-gateway
./lab-azure.sh add-team 1        # create snet-team1, deploy 4 containers and WireGuard tunnel
./lab-azure.sh add-team 2        # repeat for each additional team (same command, different N)
./lab-azure.sh add-team-range 1 20   # deploy teams 1..20 (sequential, stops on error)
./lab-azure.sh add-team-range 1 20 4 # same but 4 teams in parallel (subnets/peers sequential)
./lab-azure.sh wg-team-peer 1    # generate WireGuard tunnel for team1 (for teams deployed before gateway)
./lab-azure.sh dns-sync          # push yamls/generated/dns/*.hosts to gateway (1 call, auto-called)
./lab-azure.sh dns-sync --from-azure # rebuild full zone from 'az container list' (repair)
./lab-azure.sh dns-check <fqdn>  # resolve <fqdn> from gateway and compare with real Azure IP
./lab-azure.sh test [N]          # test shortcut: up + deploy-dmz + add-team N (N=1 default, no VPN)
./lab-azure.sh status            # status of DMZ, DMZ-VM, WireGuard gateway, and teams
./lab-azure.sh down              # delete entire Resource Group (asks for "yes" confirmation)
```

Prerequisites: `az` CLI installed and logged in (`az login`) against the "Azure for
Students" subscription in Universidad de la Sabana's tenant; `envsubst` (package `gettext-base`) for
`yamls/generate-{team,dmz,wg-client}.sh`. WireGuard client (package `wireguard-tools`) only
needed on the operator machine to use the generated `.conf` files — not a prerequisite of the script.

Design of `up`/`down`: the entire lab lives in a single Resource Group
(`rg-ctf-semana-ingenieria-test`), so "down" is a single command that destroys it all.
Maintain this invariant when extending the script — do not create resources outside the lab RG.

## Costs

```bash
az consumption usage list --output table   # detailed consumption
az billing account list -o table
az consumption budget list --output table
```

Subscription is "Azure for Students" (credit, not pay-as-you-go): `az consumption usage list`
often returns 403/AuthorizationFailed on this subscription type — not a config error, a known
limitation of Azure for Students. In that case credit balance is visible only in the portal:
portal.azure.com → Subscriptions → Azure for Students → Cost analysis (or the remaining credit
widget on the dashboard).

## Design decision: 1 YAML = 1 container = 1 IP

Each container is deployed as its own `az container create --file <container>.yaml`
(a single-container container group), not grouped with others — so each receives its own
private IP within its team subnet or DMZ, instead of sharing a single IP like the first
prototype (`team1-edificio`, now replaced).

## Design decision: xss-bot is N instances (one per team), not 1 shared bot

We considered consolidating the `xss-bot` of all teams into a single shared container (in
`snet-mgmt`, with outbound access to each `snet-teamX` but no inbound from them via NSG) to
save RAM: today it is N Playwright/Chromium containers, one per team.

We rejected it. Reason: in a CTF where teams compete by exploiting XSS against the bot, team
isolation is part of the threat model, not just a cost to optimize. A shared bot introduces:
- **Single point of failure**: if one team crashes or hangs the bot (payload `while(true)`, etc.),
  Challenge 1 fails for all teams simultaneously, not just the attacker.
- **Cross-contamination surface**: any bug in the loop visiting N teams' queues risks leaking
  cookies/timing from one team to another.
- **Unvalidated network complexity**: would require NSGs for directional isolation
  (`snet-mgmt` → `snet-teamX` yes, `snet-teamX` → `snet-mgmt` no), something the project has not
  yet tested (see NSG note in "Target network architecture").

The RAM savings do not justify that complexity preemptively. Revisit this decision only if
the real cost (measured, not estimated) becomes a problem — not before.

## Design decision: templates + generators, not static YAML

YAMLs that depend on a team number or shared secrets are not written by hand nor committed resolved:
they live as templates in `yamls/templates/*.yaml.tpl` with `${...}` variables (envsubst), and
`yamls/generate-team.sh <N>` / `yamls/generate-dmz.sh` resolve them into
`yamls/generated/*.yaml` (gitignored). `lab-azure.sh` (`add-team`, `deploy-dmz`) calls these
generators and deploys their output — no manual touching of `yamls/` in normal workflow.

- **`templates/team-*.yaml.tpl`** (database, webapp, linux-server, xss-bot) — agnostic to team
  number via `${TEAM}`; same template works for team1, team2, ..., teamN. Images
  `maosuarez/sabana-lab-*:latest` (repo `../sabana-corp-network`), subnet `snet-team${TEAM}`.
- **`templates/dmz-*.yaml.tpl`** (filesrv, parking, 11 decoy-*) — 13 containers, single
  shared deployment, independent of team number. Images in Docker Hub under `maosuarez`
  (`sabanacorp-filesrv`, `sabanacorp-parking`, `sabanacorp-decoy`), built from `../sabana-corp-dmz`
  with challenge content baked in. Fixed subnet `snet-dmz-shared`. Wiki not in ACI (see
  `deploy-wiki-vm`); its templates `dmz-wiki*.yaml.tpl` deleted because they were generated but
  never deployed.

Flags/secrets for per-team services (`FLAG_*`, `PIVOT_SSH_PASSWORD`, `BOT_SECRET`,
DB passwords, `JWT_SIGNING_SECRET`) **are identical across all teams** — sourced from
`yamls/.env.secrets` (gitignored, template in `.env.secrets.example`), never from `${TEAM}`.
Deliberate decision: CTFd validates a single flag per challenge for any team, so loading it
once in CTFd serves all N instances. DMZ secrets (parking in its template, and wiki secrets in
`generate-wiki-vm.sh`) remain as literals — the DMZ is a single deployment, not N copies.

ACI provides no DNS between distinct container groups, so a container that depends on another's IP
(`webapp`→`database`, `xss-bot`→`webapp`) cannot use the service name like in docker-compose.
`deploy_dmz`/`deploy_team` in `lab-azure.sh` solve this automatically: deploy the dependency first,
read its IP with `az container show/create --query ipAddress.ip`, and inject it via `sed` into the
dependent's generated YAML before deploying. (Wiki no longer needs this injection after migrating
from ACI to a VM with docker-compose, where inter-service name resolution is native.) See
`yamls/README.md` for deployment order details if debugging is needed.

There is a plan to set up lab internal DNS (dnsmasq on `vm-wg-gateway`, FQDNs for teams and DMZ,
resolution also from participant PC via WireGuard tunnel) in
`docs/plans/internal-dns.md` — **design, not implemented**, intended to run *after* the complete
DMZ is deployed. Note: that plan does not eliminate the IP `sed` above (deployment order still
requires it), it just adds names on top.

## Design decision: parallelism in add-team-range

Deploying a single team (`add-team N`) is sequential: subnet → containers (with
dependencies db→webapp→xss-bot) → WireGuard tunnel. The operation is slow due to the IP pool wait
in ACI (~30s per 4 containers).

`add-team-range <start> <end> [concurrency]` enables deploying multiple teams concurrently:

- **Step 1 (sequential)**: create all subnets at once (`add_team_subnet` for each team).
  Reason: concurrent `az network vnet subnet create` on the SAME VNet frequently collide
  with `409 AnotherOperationInProgress` — Azure does not permit parallel subnet operations on one VNet.
- **Step 2 (parallel, configurable limit)**: `deploy_team_workload` (YAML generation + container
  deployment) for N teams simultaneously, with concurrency limit via bash job control
  (`wait -n`). This step is the slow one: each team waits for 4 IPs (~30s); in parallel teams
  speed up (4 teams × 30s sequential = 2 min; in parallel ÷ limit of 4 ≈ 30s).
- **Step 2.5 (sequential, single push)**: `sync_lab_dns` — syncs internal DNS (see
  "Design decision: internal DNS" below) for the entire range in **one** `run-command` call,
  not one per team. Goes between step 2 and step 3 for the same reason as step 3: touches `vm-wg-gateway`.
- **Step 3 (sequential)**: `create_wg_team_peer` per team to generate WireGuard tunnels.
  Reason: peers use `az vm run-command invoke` against the same VM (`vm-wg-gateway`), which
  runs `add-peer.sh.tpl` serially — running them in parallel risks corrupting the shared config
  (`/etc/wireguard/wg0.conf`).

**General rule, not just for peers**: ALL writes to `vm-wg-gateway` go in a sequential step. It is
not just file corruption — `az vm run-command invoke` runs through the VM's RunCommand extension,
which is **single-threaded per VM**: concurrent invocations against the same machine serialize or
fail with an operation-in-progress conflict. This applies equally to WireGuard peers (step 3)
and DNS (step 2.5) — any new function that writes to the gateway (via `run-command`) must join an
existing sequential step or create its own, never run inside step 2 parallel.

Example: `./lab-azure.sh add-team-range 1 20 4` creates 20 teams with 4 in parallel (vs. 20×
sequential): subnets ~5s (step 1), workloads ~2-3 min (step 2 parallel), DNS ~10s (step 2.5,
O(1) not O(N)), peers ~20s (step 3), total ~3 min vs. ~10 min sequential.

## Design decision: internal DNS with dnsmasq on the gateway

A single `dnsmasq` instance on `vm-wg-gateway` (not a separate VM: it is the only machine already
in the path of all VPN clients and the VNet), serving a flat zone of A records generated from
real Azure state, forwarding everything else to Azure DNS (`168.63.129.16`).

- **Domain `sabanacorp.internal`, explicitly not `.local`**: `.local` is reserved by RFC
  6762 for mDNS/Bonjour — on macOS (always) and Linux with `avahi` (Ubuntu desktop, by
  default), a query to `algo.local` resolves via multicast on the local network instead of going to
  the configured DNS. This would be the worst possible bug for an event: works on the operator's
  machine, fails randomly on a participant's MacBook, nothing in the logs. `.internal` is an ICANN-reserved
  (2024) TLD for private use, never delegated or intercepted.
- **Flat zone, no split-horizon**: everyone resolves everything (except `snet-mgmt`, not
  published). Discovering `webapp.team7.sabanacorp.internal` is reconnaissance — CTF flavor, not
  a leak — and the real boundary already exists and is tested: it is `iptables` on the gateway
  (resolves, cannot reach), not DNS.
- **Most important: to avoid discovering this the hard way later**: container environment variables
  (`DB_HOST`, `WEBAPP_BASE_URL`) **stay as IPs on purpose, with `sed` intact**. DNS is a name
  layer for humans/tools/navigation within the CTF, NOT the challenge data plane. If someone "fixes"
  `<DATABASE_IP>` by putting an FQDN in it, DNS becomes a hard dependency of all challenges, without
  anyone deciding so — do not do this without re-reading `docs/plans/internal-dns.md` ("The chicken
  and the egg") first. Direct consequence: a crashed dnsmasq does not take down any already-deployed
  challenge.
- Commands: `dns-sync [--from-azure]`, `dns-check <fqdn>`. Full detail, test plan,
  risk matrix, and client WireGuard OS behavior (real split-DNS on Windows/macOS, not-so-real on
  Linux) in `docs/plans/internal-dns.md`.

## Target network architecture

**vnet-ctf-lab** (`10.0.0.0/8`) — internet-isolated network, reachable only after breaking through
a captive portal + VPN.

- **snet-dmz-shared** (`10.50.0.0/24`) — services shared by all teams:
  - CTFd (flags and scoreboard) — implemented and validated end-to-end (2026-08-11), but lives in
    `snet-dmz-vm`, not here (same exclusive-delegation limitation to ACI that removed the wiki,
    see `snet-dmz-vm` below). See `docs/plans/ctfd-deployment.md`
  - Provisioner (FastAPI) — talks to Azure/VPC API to provision team resources — not yet implemented
  - XSS bot target — implemented as `filesrv`/`wiki`/`parking`/decoys (see `yamls/templates/dmz-*.yaml.tpl`);
    the admin bot itself lives in `xss-bot` per team (`snet-teamN`), not in DMZ
- **snet-teamX** (`10.60.X.0/24`, one per team, `X` = team number) — dedicated network per
  team, created on-demand with `./lab-azure.sh add-team <X>`:
  - File-Srv — vulnerable to anonymous access, pivot to next level (lives in shared DMZ, not here — see note below)
  - Wiki-Int — cryptography hints (idem, shared DMZ)
  - Decoy services — simulate corporate noise (idem, shared DMZ)
  - Parking — final challenge (idem, shared DMZ)
  - What actually lives in `snet-teamX`: `database`, `webapp`, `linux-server`, `xss-bot`
    (challenges 1-3 of the building challenges per team)
- **snet-mgmt** (`10.99.0.0/24`) — management network, created by `up`. Hosts `vm-monitor`
  (Prometheus + blackbox_exporter + Grafana + node_exporter, no public IP), created by
  `./lab-azure.sh deploy-monitor-vm` — **validated end-to-end 2026-08-10**, see
  `docs/plans/observability-monitoring.md`. Grafana reachable only via WireGuard admin tunnel;
  `snet-mgmt` not published in internal DNS on purpose (see "Design decision: internal DNS"
  above). Do not confuse with `dmz-decoy-monitor` (profile `monitor`, CTF decoy in
  `snet-dmz-shared` that mimics Grafana/Prometheus and does not monitor anything).
- **snet-dmz-vm** (`10.51.0.0/24`) — parallel DMZ for services that do not run in ACI. Currently hosts
  `vm-wiki` (wiki + wiki-db via docker-compose), migrated from ACI because BookStack requires
  real PID 1 (s6-overlay, ACI+VNet limitation — validated end-to-end 2026-08-08). Cannot go in
  `snet-dmz-shared` because that subnet is delegated to `Microsoft.ContainerInstance/containerGroups`
  (exclusive delegation, VMs not supported). See `docs/plans/wiki-on-vm.md` for details. Also hosts
  (`./lab-azure.sh deploy-ctfd-vm`, **validated end-to-end 2026-08-11**) `vm-ctfd`: nginx +
  ctfd/gunicorn + MariaDB + Redis via docker-compose, same reason (full upstream docker-compose,
  not worth splitting into ACI YAML). See `docs/plans/ctfd-deployment.md`.
- **snet-wg-gateway** (`10.10.0.0/28`) — sole lab entry point **and lab internal DNS**:
  `vm-wg-gateway` (public IP, WireGuard UDP 51820, static private IP `10.10.0.4`), created by
  `./lab-azure.sh deploy-wg-gateway`. `add-team <N>` automatically generates that team's tunnel
  (access only to its own `snet-teamN` + both DMZ subnets) and a `.conf` in `yamls/generated/wg-clients/`;
  there is also an admin tunnel with access to all of `10.0.0.0/8`. Per-tunnel access control is
  applied via `iptables` on the VM itself, not NSGs (more detail, validation, and test status in
  `docs/plans/wireguard-vpn-gateway.md`, **validated end-to-end 2026-08-08**). Also runs `dnsmasq`
  (domain `sabanacorp.internal`, private IP `10.10.0.4` for VNet, tunnel IP `10.200.0.1` for VPN
  clients) — see "Design decision: internal DNS" below and `docs/plans/internal-dns.md`.

Implementation note vs. original architecture: File-Srv/Wiki-Int/decoys/Parking were initially
described as part of each team's network, but the `sabana-corp-dmz` repo implemented them as a
single shared deployment in `snet-dmz-shared` (see `../sabana-corp-dmz/README.md`). This real
implementation was followed instead of the original description — if they are separated per team
later, this section must be revisited.

VPN connector: implemented and validated end-to-end 2026-08-08, see `docs/plans/wireguard-vpn-gateway.md`.

**Network segmentation (`docs/plans/network-segmentation-nsgs.md`): all 3 steps implemented and
validated end-to-end 2026-08-14.** Found live: a participant legitimately reached their own
`team1-linux-server` through the VPN as intended, then pivoted from that box straight into
`team2-linux-server` — the earlier framing of this risk ("only reachable if entering outside the
VPN gateway") was wrong; the gateway's `iptables` only controls what a VPN *client* can reach
directly, it says nothing about what an already-reachable host can reach next once traffic is
inside the VNet. Before this fix, not a single NSG existed on `snet-team*`/`snet-dmz-*`/`snet-mgmt`
(only `nsg-wg-gateway`, VPN inbound). Fix, one NSG per subnet (`lab-azure.sh`):

- `nsg-team<N>` (`create_team_nsg`) — allows only that team's own `/24`, denies the rest of
  `10.60.0.0/16`, both directions (team↔team isolation).
- `nsg-dmz-shared` / `nsg-dmz-vm` (`create_dmz_shared_nsg` / `create_dmz_vm_nsg`) — deny outbound
  to the team supernet and to `snet-mgmt`; DMZ-shared↔DMZ-vm and inbound (teams/mgmt reaching DMZ)
  stay open.
- `nsg-mgmt` (`create_mgmt_nsg`) — denies inbound from the team supernet and both DMZ prefixes,
  enforced once on mgmt's own NSG rather than duplicated on every other subnet. `mgmt →
  everything` (monitoring scrapes) stays open, unaffected since it's stateful return traffic /
  outbound from mgmt's side.

Wired into `create_vnet()`/`add_team_subnet` so every new subnet gets its NSG automatically;
`./lab-azure.sh secure-network` retrofits infrastructure created before this fix (`secure-teams`
still works standalone for teams only). Verified live end-to-end: every cross-boundary path the
matrix denies (team↔team, DMZ→teams, DMZ→mgmt, team→mgmt) drops; every path it allows (intra-team,
team→DMZ, DMZ↔DMZ, mgmt→teams/DMZ) stays open. See `docs/plans/network-segmentation-nsgs.md` for
the full matrix and verification detail.

## File notes

- `lab-azure.sh` — orchestrates the full lifecycle: base infrastructure (`up`), DMZ
  (`deploy-dmz`), teams (`add-team <N>`, `add-team-range`), wiki-vm (`deploy-wiki-vm`), ctfd-vm
  (`deploy-ctfd-vm`, validated end-to-end 2026-08-11), monitor-vm
  (`deploy-monitor-vm`), VPN gateway (`deploy-wg-gateway`), internal DNS (`dns-sync`,
  `dns-check`), status (`status`), and teardown (`down`). Calls the `yamls/` generators and
  resolves IP dependencies between containers. Implements configurable parallelism in
  `add-team-range` (sequential subnets, parallel workloads, single DNS push, sequential peers).
- `.env` — `DOCKERHUB_USER` / `DOCKERHUB_TOKEN`; the script does not load it automatically,
  variables must be exported manually before running any container deployment command.
- `yamls/` — templates, generators, and per-container deployment documentation. Includes:
  - `templates/*.yaml.tpl` + `generate-*.sh` for DMZ/teams/wiki-vm/ctfd-vm/monitor-vm/WireGuard
    clients
  - `generate-dns-hosts.sh` — generates DNS zone blocks (`generated/dns/*.hosts`)
  - `wg-gateway/` — cloud-init VM (WireGuard + dnsmasq), remote scripts for peer and
    gateway DNS zone management
  - `ctfd-vm/` — cloud-init VM (Docker) + `conf/nginx/http.conf` vendored from
    `../sabana-corp-CTFd`. `generate-ctfd-vm.sh` builds the bundle in `generated/ctfd/` (secrets
    from `.env.secrets`, `CTFD_*` block, unlike the wiki). See
    `docs/plans/ctfd-deployment.md`.
  - `monitor/` — cloud-init VM, docker-compose (Prometheus + blackbox_exporter + Grafana +
    node_exporter), probe config (`prometheus/`, `blackbox/`), Grafana provisioning
    (datasource + dashboards "Team Dashboard"/"DMZ Dashboard" + Unified Alerting rules) and
    `remote/gen_targets.py` (discovery via `az container list`, runs on `vm-monitor` every
    60s via systemd timer). See `docs/plans/observability-monitoring.md`.
  - `generated/` (gitignored) — resolved YAML, generated WireGuard clients, DNS zone blocks,
    and `vm-monitor` bundle
  See `yamls/README.md` for details.

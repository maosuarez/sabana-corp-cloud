# Plan: central observability (Prometheus + Grafana in snet-mgmt)

## Status

**F1 (base stack + discovery) and F2 (alerting rules) implemented and validated against real Azure
on 2026-08-10.** `./lab-azure.sh deploy-monitor-vm` creates `vm-monitor`; `status` now includes
its section. F3 (`restore team/dmz`) and F4 (logs) still not implemented. See `yamls/README.md`
"Observabilidad" for operational details (host paths, gen_targets.py, etc).

Two corrections to the original design of this document, discovered when deploying against
real Azure:

1. **"A single `az container list`" is not enough for control plane status.** The
   "Design decision: discovery" section below assumed that `instanceView.state` and
   `containers[0].instanceView.restartCount` came populated in `az container list`. That is not
   true — it is the same limitation that already forced `print_container_states()` (`lab-azure.sh`) to
   use `az container show` per container. The blackbox *targeting* (IP:port, which does come
   in `list`) was not affected; control plane status (secondary signal "b") refreshes
   separately, every 5 min, parallelized with `az container show` per container and cached — it remains
   much less aggressive than 93 calls/min, and the primary signal (blackbox) does not depend on
   this.
2. **`GatewaySinHandshakes` was not implemented.** It would require the managed identity of
   `vm-monitor` to invoke `run-command` against `vm-wg-gateway` (read `wg show wg0`), a broader role
   than `Reader` on the RG — it was not justified to expand the identity's scope just
   for this alert (see "Risks" below, which already warned about this). Like `BotColgado` (blocked
   by the pending health endpoint in `bot.js`), it remains as future work.

Do not confuse with `dmz-decoy-monitor` (`sabanacorp-decoy`, `monitor` profile, ports 3000/9090 in
`snet-dmz-shared`): that is a CTF decoy that mimics a Grafana/Prometheus and monitors
nothing. The real stack of this plan lives in `snet-mgmt` and is called `vm-monitor`.

## Motivation

During the event there are ~93 live endpoints (20 teams × 4 containers + 13 from DMZ + `vm-wiki` +
`vm-wg-gateway`). Today there is no way to know that Challenge 1 of team 14 has been down for 20 minutes
unless team 14 complains. The goal of this plan is not "to have pretty metrics", it is
to answer two questions in less than a minute:

1. **What is broken and whose is it?** (service + team, not an aggregated average)
2. **Is restarting it enough?** (distinguish a crashed container from a hung service from a broken dependency)

Requirements:
- Zero changes to challenge images, except for one justified exception (`xss-bot`, below).
- Automatic discovery: `add-team 15` should appear on the dashboard without editing config.
- No public IP. Accessed via the WireGuard admin tunnel.
- Must fit within quota (10 regional vCPUs).

## Design decision: external probing (blackbox), no agents in containers

Three options evaluated:

**a) Exporters/sidecars in each container group.** Rejected. It requires touching 4 team templates
and 13 DMZ ones; that is ~93 extra processes of RAM; and —the decisive factor— the exporter ends up
*inside* the team's network, where the participant has root on `linux-server` after Challenge 2.
They can read it, falsify it, or use it to discover the existence and IP of the monitor. In a CTF, the
monitoring agent is attack surface, not just a cost. Same reasoning as the decision that
"xss-bot is N instances, not 1 shared bot" in `CLAUDE.md`.

**b) Azure control plane only** (`az container list` → `instanceView.state`, `restartCount`).
Zero intrusion, but it only says "the container is Running". A MariaDB with a corrupted database,
a webapp returning 500, or an `xss-bot` with Chromium hung all look green.
Necessary, but insufficient alone.

**c) `blackbox_exporter` from `snet-mgmt`.** Prometheus probes TCP/HTTP against the real IP:port
of each service, from outside, exactly as the participant would. Zero changes to images.

**We choose (c) as the primary signal and (b) as the secondary signal.** Together they distinguish the three
states that matter operationally:

| Control plane | Blackbox probe | Diagnosis | Action |
|---|---|---|---|
| Running | OK | healthy | none |
| Running | fails | hung service or broken dependency | restart container |
| Terminated / restartCount rising | fails | crash loop | check logs before restarting |
| does not exist | fails | group deleted | redeploy (`restore`) |

## Design decision: discovery via `az container list`, no static targets

This is the real problem of the plan, not Grafana.

ACI does not provide DNS between container groups (already documented in `CLAUDE.md`), so there is no
stable name to scrape. And private IPs **are not stable on recreation**: if a container
group is deleted and recreated, it gets another IP from the subnet's pool. A manually written `targets.yml`
becomes obsolete at the first restore.

Solution: `gen-targets.sh` in `vm-monitor`, running every 60s via systemd timer:

```bash
az container list -g "$RG" \
  --query "[].{name:name, ip:ipAddress.ip, state:instanceView.state}" -o json \
  | jq '...'  > /etc/prometheus/targets/aci.json
```

A single call to the control plane for the entire RG (not one per group — that would hit
rate limits at 93 groups). Output in Prometheus `file_sd` format, with labels derived from the
container group name:

| Container group | `job` | `team` | `service` |
|---|---|---|---|
| `team7-webapp` | `building` | `7` | `webapp` |
| `dmz-filesrv` | `dmz` | `-` | `filesrv` |
| `dmz-decoy-mail` | `dmz-decoy` | `-` | `decoy-mail` |

The same script emits control plane metrics (state, `restartCount`) via textfile
collector — so both (b) and (c) come from the same pass and no separate Azure exporter is needed.

Authentication: **managed identity** in `vm-monitor` with `Reader` role on the RG. No service
principal, no credentials on disk. See "Risks" — that identity is the most valuable asset in
`snet-mgmt`.

## Design decision: visual alerting in Grafana, no Alertmanager

The staff operates the event in-person with a dashboard on screen. Alertmanager is not deployed
nor notifications to Telegram/Discord/email: it would be extra infrastructure, another channel to
maintain, and a dependency on outbound internet for a problem already solved by a monitor
running with someone watching it.

A significant design consequence: **the dashboard must be readable from three meters away**,
because it is the only alert channel. No line graphs as the main panel.
The primary panel is a status wall (`Status history` / colored cells), one row per team,
one column per service, green/red. A red is visible from the other side of the room; a p95 in a graph is not.

Grafana Unified Alerting is still used, but only for the visual alert state and its history
(when it started, how long it has been), without contact points. If the event is later operated remotely,
adding a webhook is an hour of work and changes nothing of the above.

## The blind spot: `xss-bot`

`bot.js` (repo `sabana-corp-network`) **does not listen on any port** — the `port: 80` in
`team-xss-bot.yaml.tpl` is a placeholder that ACI requires for `ipAddress: Private`, and is
commented as such in the template. There is nothing to probe.

Worse: its main loop catches all exceptions and keeps running.

```js
} catch (err) {
    // The webapp may not be ready on startup: retry in the next cycle.
    console.error('[bot] Error in polling cycle:', err.message);
}
```

`chromium.launch()` is **outside** the loop. If the browser dies —which is the expected failure mode,
because participants throw payloads at it on purpose— each `visitTicket` throws,
the catch swallows it, and the process runs forever without visiting anything. The process never exits,
so `restartPolicy: OnFailure` never triggers and the control plane reports `Running` forever.
Challenge 1 is broken and all signals are green.

**Solution: health endpoint in `bot.js`.** This is the only exception to "do not touch images", and it is
justified because there is no external alternative. A minimal HTTP server (`node:http`, no
new dependencies) on port 80 that the template already declares:

```json
{"ok": true, "last_visit_ts": 1754700000, "last_error": null, "browser_alive": true}
```

- `last_visit_ts`: timestamp of the last successfully completed cycle. The Prometheus probe fails
  if it is older than `3 × BOT_VISIT_INTERVAL_SECONDS` (90s by default). That converts "the bot
  is doing its job" into a measurable signal, which is different from "the process is alive".
- `browser_alive`: `browser.isConnected()`. Detects the Chromium crash directly.

Exposure risk: low. The endpoint is only reachable from `snet-teamN` (its own team)
and from that team's tunnel; it reveals no flags or `BOT_SECRET`; and a health service in the
corporate network fits with the ambient noise of the scenario. Still, it must not reflect
ticket contents or cookies.

Complementary change recommended in the same PR (independent of monitoring, but is the bug that
monitoring will expose): move `chromium.launch()` inside the loop with restart if
`isConnected()` is false.

## Probe inventory

`tcp_connect` probe except where otherwise noted. Decoys are probed only on their main port
(they are scenario noise; what matters is that they are up, not measuring every port).

**Per team** (`snet-teamN`, `10.60.N.0/24`), ×20:

| Service | Port | Probe |
|---|---|---|
| `database` | 3306 | `tcp_connect` (no auth — do not authenticate against the challenge DB) |
| `webapp` | 80 | `http_2xx` to `/` (accepts 200/302) |
| `linux-server` | 22 | `ssh_banner` |
| `xss-bot` | 80 | `http_2xx` to `/health` + freshness of `last_visit_ts` |

**Shared DMZ** (`snet-dmz-shared`, `10.50.0.0/24`):

| Service | Port | Probe |
|---|---|---|
| `dmz-filesrv` | 8080 | `http_2xx` |
| `dmz-parking` | 8080 | `http_2xx` |
| `dmz-decoy-printer` | 80 | `tcp_connect` |
| `dmz-decoy-nas` | 445 | `tcp_connect` |
| `dmz-decoy-legacy-web` | 80 | `tcp_connect` |
| `dmz-decoy-database` | 3306 | `tcp_connect` |
| `dmz-decoy-camera` | 554 | `tcp_connect` |
| `dmz-decoy-backup` | 873 | `tcp_connect` |
| `dmz-decoy-admin` | 8443 | `tcp_connect` |
| `dmz-decoy-ftp` | 21 | `tcp_connect` |
| `dmz-decoy-monitor` | 3000 | `tcp_connect` |
| `dmz-decoy-git` | 9418 | `tcp_connect` |
| `dmz-decoy-mail` | 25 | `tcp_connect` |

**VMs:**

| Host | Probe |
|---|---|
| `vm-wiki` (`snet-dmz-vm`) | `http_2xx` to `:80`; also `docker compose ps` via `az vm run-command` in the targets script |
| `vm-wg-gateway` (`snet-wg-gateway`) | `wg show wg0` via `az vm run-command`: number of peers and age of last handshake |
| `vm-monitor` | local `node_exporter` (this one is ours; here an agent is not attack surface) |

Scrape interval: 15s. With ~95 targets and TCP probes that is negligible load for a D2s_v7.

## Alerts

Few and actionable. Each one must have an obvious associated action; if it doesn't, it is a panel,
not an alert.

| Alert | Condition | Severity | Action |
|---|---|---|---|
| `ServiceDown` | `probe_success == 0` for >60s | critical | `restore` the service |
| `BuildingDown` | all 4 services of a `team` down | critical | check the subnet/team IP pool, not containers one by one |
| `CrashLoop` | `restartCount` rises ≥3 in 10 min | critical | check logs **before** restarting |
| `BotHung` | `last_visit_ts` older than 90s, or `browser_alive == false` | critical | restart `teamN-xss-bot` |
| `IPDrift` | injected IP in dependent ≠ current IP of its dependency | critical | `restore` the dependent (see below) |
| `DMZDegraded` | any DMZ service down | critical | affects **all** teams, highest priority |
| `DecoyDown` | a decoy down >5 min | low | cosmetic, blocks no challenges |
| `GatewayNoHandshakes` | 0 handshakes in 5 min with configured peers | critical | no one can enter the lab |
| `DNSDown` | TCP/UDP 53 probe to `10.10.0.4` fails | medium | no one resolves names, but no challenge crashes (env vars still in IP — see `docs/plans/internal-dns.md` "Resilience") |

### The alert that doesn't exist in any standard stack: `IPDrift`

`deploy_team` solves the lack of DNS by reading the dependency's IP and **baking it with `sed`**
into the dependent's YAML before deploying it: `webapp` carries the IP of `database` inside,
`xss-bot` carries `webapp`'s. (The wiki now lives on a VM with docker-compose, where name resolution between services is native.)

Consequence: **recreating a container group can silently break its dependents.** If
`team7-database` is recreated and gets a different IP, `team7-webapp` keeps Running, keeps responding 200 on
`/`, and only fails when accessing the database — a partial failure that no availability probe detects
and that shows green on the wall.

That is why the targets script compares, for each dependent, the IP it has injected
(`az container show --query "containers[0].environmentVariables"` or the generated YAML in
`yamls/generated/`) against its dependency's current IP, and exports
`sabana_ip_drift{team,service} = 0|1`. This is the most specific alert to this architecture and the
only one that doesn't come free from Prometheus.

The internal DNS (`docs/plans/internal-dns.md`, implemented) **does not replace this alert** —
a deliberate decision of that plan: challenge env vars stay on IP on purpose, so
`webapp` can keep the old IP of `database` even if DNS already knows the new one. `IPDrift`
now has a cheap-to-compute sister via the same mechanism: compare the DNS record
(`dns-check <fqdn>`) against Azure's real IP — detects when the *local zone* gets out of sync,
not when a container got stuck with the old baked IP (two different failures, same shape).

## Observing is not restoring: `restore` subcommands

A dashboard that detects but does not fix leaves the operator improvising `az container create` by hand during the event. Missing from `lab-azure.sh`:

```bash
./lab-azure.sh restore team <N> <service>   # database | webapp | linux-server | xss-bot
./lab-azure.sh restore dmz <service>
```

Semantics, in order:

1. `az container restart` if the group exists and is not in a crash loop (fast, preserves the IP).
2. If it doesn't exist or restart fails: regenerate the YAML and `az container create` (this **can**
   change the IP).
3. **Always, at the end: re-resolve and re-inject dependency IPs downstream.** Restoring
   `database` means redeploying `webapp`; restoring `webapp` means redeploying `xss-bot`. This
   step is what makes the command correct and not just convenient, and it is the direct counterpart
   of the `IPDrift` alert.

It reuses `deploy_team_workload` and the IP injection logic that already exist; it is not new code,
it is exposing what `add-team` already does at the level of a single service.

## Access

Grafana at `10.99.0.x:3000`, **no public IP**. Reached via the WireGuard admin tunnel, which already
has `AllowedIPs = 10.0.0.0/8` and therefore covers `snet-mgmt` without touching the gateway config.
Team tunnels cannot reach it: their `iptables` on `vm-wg-gateway` only allow their own
`snet-teamN` + both DMZ (validated end-to-end on 2026-08-08, see
`docs/plans/wireguard-vpn-gateway.md`).

An explicit `FORWARD` rule in the gateway for `admin → 10.99.0.0/24` may be needed if the
admin's `iptables` enumerates subnets instead of allowing `10.0.0.0/8` plainly — verify against
the real implementation of `add-peer.sh.tpl` when implementing F1.

## Cost and quota

| | vCPU |
|---|---|
| `vm-wiki` (D2s_v7) | 2 |
| `vm-wg-gateway` (D2s_v7) | 2 |
| `vm-monitor` (D2s_v7) | 2 |
| **Total** | **6 / 10** |

Quota verified on 2026-08-09: `Total Regional vCPUs` 10, `Standard Dsv7 Family vCPUs` 10, 0 in
use with the lab down. 4 vCPU margin remains. The ~93 ACI container groups do not consume VM quota.

D2s_v7 (2 vCPU / 8 GB) is more than enough for Prometheus with ~95 targets at 15s and multi-day retention. If
Loki is added in F4, check disk, not CPU.

## Phases

### F1 — Base stack and discovery

- Subcommand `deploy-monitor-vm` in `lab-azure.sh`: `vm-monitor` D2s_v7 in `snet-mgmt`, no public IP,
  managed identity with `Reader` on the RG. Same pattern as `deploy-wiki-vm`.
- cloud-init + `docker-compose`: `prometheus`, `blackbox_exporter`, `grafana`, `node_exporter`.
  Templates in `yamls/monitor/`, consistent with `yamls/wg-gateway/`.
- `gen-targets.sh` + systemd timer (60s) → `file_sd` with labels `job`/`team`/`service`.
- "Team wall" dashboard: one row per team, one column per service, green/red, readable from three
  meters. A second dashboard for DMZ.
- Datasource and dashboard provisioning as code (`grafana/provisioning/`), no clicks — the
  stack must survive a `down`/`up` of the RG.

### F2 — Alerting rules

- The 8 rules from the table in Grafana Unified Alerting, no contact points.
- `sabana_ip_drift` in `gen-targets.sh` (textfile collector) and its rule.
- Active alerts panel, sorted by severity, on the same wall.

### F3 — `restore` in `lab-azure.sh`

- `restore team <N> <service>` and `restore dmz <service>` with the 3-step semantics above.
- Reuse `deploy_team_workload` and existing IP injection.
- Link the exact command from each alert's description in Grafana (operators copy-paste, they don't
  remember syntax at 2am).

### F4 — Logs

- ACI Diagnostics → Log Analytics Workspace in the same RG (native, no agent in the
  container needed; the volume of a few-hour event is cheap).
- Azure Monitor datasource in Grafana → the crashed container's logs one click from the red panel.
- Alternative considered and rejected: Promtail/Loki. Cannot read logs from an ACI container
  group without a sidecar, which is exactly what this plan avoids.

**F1 and F2 are the minimum useful.** F3 is what makes the plan operable during the event.
F4 is post-mortem diagnostics and can be deferred if time is tight.

## Risks and things to watch

- **The managed identity is the most valuable asset in `snet-mgmt`.** A `Reader` on the RG exposes
  the complete lab topology. Today, inside the VNet, any subnet can reach `snet-mgmt`
  (Azure routes between subnets of the same VNet and no NSG is created). The VPN gateway
  blocks teams, but does not protect against a pivot *inside* the VNet. This raises the
  priority of `docs/plans/network-segmentation-nsgs.md`, at least the deny rule
  `snet-team*` → `snet-mgmt`. Minimum scope: `Reader` on the RG, never on the subscription.
- **Control plane rate limits.** One `az container list` for the entire RG every 60s is one call;
  one per container group would be 93 and ARM will throttle them. Do not degrade the script to
  a loop of `az container show` "to get more detail".
- **Do not confuse `vm-monitor` with `dmz-decoy-monitor`.** Names, Prometheus labels, and
  dashboard titles must make clear which is which; the decoy exposes 3000/9090 precisely to
  look like this.
- **The probe must not be a hint for the CTF.** `tcp_connect` against `database` is fine;
  do not authenticate. No probes that leave traces in a challenge's logs in a way that confuses
  the participant (or worse, reveals the existence of the management network).
- **`down` deletes the entire RG**, monitor included. Project invariant (`CLAUDE.md`),
  respect it: nothing of the stack outside the lab RG, and all Grafana config provisioned as
  code so it can be reconstructed.
- **The xss-bot health endpoint is a change in `sabana-corp-network`**, not this repo.
  It requires rebuilding and republishing `maosuarez/sabana-lab-xss-bot:latest`, and coordinating
  with that repo's deployment cycle.
- **The delegation of `snet-dmz-shared` to ACI does not apply to `snet-mgmt`.** `snet-mgmt` is not
  delegated, which is why it accepts VMs. Never delegate it to `Microsoft.ContainerInstance/containerGroups`
  or `vm-monitor` will no longer be able to exist there (same issue that forced `snet-dmz-vm`, see
  `docs/plans/wiki-on-vm.md`).

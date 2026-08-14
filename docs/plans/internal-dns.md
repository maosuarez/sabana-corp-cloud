# Plan: Lab internal DNS (dnsmasq on vm-wg-gateway)

## Status

**Validated against real Azure (2026-08-10).** Phase 0 (4 assumption checks) and Phase 1 (dnsmasq installation on the existing VM) completed without recreating `vm-wg-gateway` — the `.conf` files already delivered to `team1`/`team2` were preserved. `dns-sync --from-azure` and `dns-check` validated end-to-end on live gateway: zone rebuilt from `az container list` (22 records: 8 from two teams, 14 from DMZ and infra) and DNS round-trip verified. **Bug found and repaired**: `yamls/generate-dns-hosts.sh`, function `dmz_hosts_line()`, had printf format with 3 placeholders `%s.dmz.%s` but only 2 distinct arguments — duplicated canonical name instead of pairing canon with alias. Repaired and resynced to live gateway (DMZ records now show canon/alias pairs correctly, e.g., `printer-01.dmz.sabanacorp.internal printer.dmz...`).

**Caveat**: containers already deployed before this session (team1, team2, 13 DMZ) do NOT have `dnsConfig` applied yet — only those deployed from now on (via `add-team <N>` or `deploy-dmz` redeploy) receive it, because changing `dnsConfig` on an existing container group requires recreation (new IP, redeployment of dependents). Deliberately left untouched (operational decision: don't recreate without explicit consent) — the DNS system works completely for these containers as **resolution targets** (their IPs are registered and resolve, validated above); they just can't resolve names from inside their own `resolv.conf` until redeployed.

**Execution timing: after the complete DMZ is deployed.** This is an explicit requirement, not an ordering preference. Concrete reasons:

- The DNS zone is built by reading the real Azure state (`az container list` / the IPs that `deploy_team_workload` already knows). Setting it up against a partial DMZ means rewriting it entirely when CTFd/Provisioner/Monitor arrive, and dragging a naming scheme decided without knowing all services needing names.
- This plan **adds a new dependency to `vm-wg-gateway`** (which today only does VPN). Adding that dependency while the DMZ is still stabilizing mixes two failure surfaces that should be debugged separately.
- Nothing in the DMZ or the challenges depends on this plan to function (see "Resilience"): it's a layer of convenience and narrative, not data plane.

Hard prerequisites before starting Phase 1:

1. Shared DMZ deployed and stable (`deploy-dmz` + `deploy-wiki-vm`).
2. `vm-wg-gateway` deployed and validated end-to-end (already is since 2026-08-08, see `docs/plans/wireguard-vpn-gateway.md`).
3. At least two teams deployed (`team1`, `team2`) to test the "resolves but can't reach" case that defines the security model.

## Problem

Today everything in the lab is addressed by raw IP, and that hurts in three different places:

1. **For participants and staff.** A team entering via VPN gets a `.conf` and a list of IPs (`10.60.3.5:80`, `10.50.0.6:8080`, ...). There's no way to say "go to helpdesk" without also saying "it's .5 today, but if we redeploy it's something else". It breaks the fiction of "Sabana Corp is a company" — a company has names, not an IP spreadsheet — and turns any CTF guide or hint into a document that expires with each redeployment. The repo itself half-lives this fiction: `wiki-vm-compose.yml.tpl` sets `APP_URL: "http://wiki-int.empresa.local"`, a name that **doesn't resolve anywhere**.

2. **For dependent containers.** `ACI doesn't provide DNS between distinct container groups` (documented in `CLAUDE.md` and `yamls/README.md`), so `deploy_team_workload()` deploys `database`, reads its IP with `wait_for_ip`, and bakes it with `sed` into `webapp`'s YAML (`lab-azure.sh:271`); same for `webapp` → `xss-bot` (`lab-azure.sh:277`). The IP stays **frozen inside the container**, producing the silent failure that `docs/plans/observability-monitoring.md` already named `IPDrift`: if `team7-database` is recreated with a different IP, `team7-webapp` stays Running, keeps returning 200 on `/`, and only fails when touching the database.

3. **For running the event.** Diagnosing "challenge 1 for team 14" means cross-referencing `az container list` with the operator's memory. With names, it's `curl http://helpdesk.team14.<domain>`.

This document fully resolves (1) and (3), and (2) **only partially and intentionally** — the "Chicken and egg" section explains why, and why that's fine.

## Design decision: dnsmasq on vm-wg-gateway, flat zone, served to the VNet and tunnel

A single `dnsmasq` on `vm-wg-gateway`, listening on `wg0` (for VPN clients) and on `eth0` (for ACI containers), serving a flat zone of A records generated from real Azure state, and forwarding everything else to Azure DNS (`168.63.129.16`).

Why on `vm-wg-gateway` and not a separate VM:

- It's **the only machine already in everyone's path**: VPN clients exit through it and the whole VNet reaches it. A separate `dns-server` would add a VM (2 vCPU out of a 10-vCPU quota, see `docs/plans/wiki-on-vm.md`) for a process consuming ~15 MB of RAM.
- The machinery to write to that VM already exists (`az vm run-command invoke` + `yamls/wg-gateway/remote/*`), validated end-to-end.
- Its overlay IP (`10.200.0.1`) is **fixed by design** (set by `cloud-init.yaml`), so the WireGuard client's `DNS =` is a constant, not a value needing discovery.
- If the gateway goes down, there's no lab from outside anyway — DNS doesn't add a *new* single point of failure for remote access. (It would for containers; see "Resilience", which is exactly why we keep env vars on IP.)

### Discarded alternatives

**Azure Private DNS Zone.** Rejected for two independent reasons, either one sufficient:
- ACI container groups injected into a VNet **don't self-register** in a Private DNS Zone (self-registration of virtual network links only covers VM NICs). Each A record would need to be created manually with `az network private-dns record-set a add-record` — same synchronization work as with dnsmasq, but against Azure's control plane and with its latency, gaining nothing.
- A Private DNS Zone only resolves by querying `168.63.129.16`, a *platform link-local address*: it only responds to resources within the VNet. **From the participant's PC, on the other side of the WireGuard tunnel, it's unreachable.** And requirement 1 of this plan is exactly to resolve from the operator/team's PC. You could set up a forwarder on the gateway to forward to `168.63.129.16`... which is literally dnsmasq, but with twice the moving parts and another zone to maintain.

**Generated and distributed `/etc/hosts`.** Rejected. It could work for containers (would need mounting, and ACI doesn't support bind mounts for loose files) and especially **doesn't work for the participant**: it would mean asking each team to edit `/etc/hosts` or `C:\Windows\System32\drivers\etc\hosts` as root/admin on machines we don't control, and redo it every time an IP changes. Plus it turns every IP change into a support incident during the event instead of a line in a file on the gateway.

**CoreDNS (in ACI or on the VM).** Rejected for over-engineering at this scale. CoreDNS offers over dnsmasq: view plugins (`view`), Kubernetes integration, and native Prometheus metrics. None of that is used here — no Kubernetes, the "no split-horizon" decision (below) removes the need for `view`, and DNS metrics aren't in `docs/plans/observability-monitoring.md`'s design. In exchange, it would require managing a Corefile + zones, or running it in ACI (where it can't listen on `wg0` and we're back to the tunnel problem). dnsmasq reads `/etc/hosts` format files, the simplest format that exists to generate with bash and to read at 3 AM on event day.

**One dnsmasq per team (for split-horizon).** Rejected; see "Isolation".

## Naming scheme

### Domain: `sabanacorp.internal` — explicitly **not** `.local`

`.local` is reserved by RFC 6762 for **mDNS/Bonjour**. On macOS (always) and on many Linux distros with `avahi`/`nss-mdns` installed (Ubuntu desktop, by default), a query for `something.local` **is not sent to the configured DNS server**: it resolves via multicast on the local network. The result would be exactly the worst kind of bug for an event: works on the operator's machine (WSL2, no avahi), fails on a participant's MacBook, symptom is "sometimes resolves" with nothing in the gateway logs.

`.internal` was designated by ICANN (2024) as a permanently reserved TLD for private use — never will be delegated, no public resolver will intercept it, no OS stack will. `sabanacorp.internal` is used.

The domain lives in **a single variable** (`LAB_DOMAIN` in `lab-azure.sh`, exported to generators), so changing it is one edit and a `dns-sync`. Note: need to align `yamls/templates/wiki-vm-compose.yml.tpl` (`APP_URL: http://wiki-int.empresa.local`), which today points to a made-up name that doesn't resolve.

### Format

| What | Canonical FQDN | Additional aliases |
|---|---|---|
| team N webapp | `webapp.team<N>.sabanacorp.internal` | `helpdesk.team<N>...` |
| team N database | `database.team<N>.sabanacorp.internal` | `db.team<N>...` |
| team N linux-server | `linux-server.team<N>.sabanacorp.internal` | `pivot.team<N>...` |
| team N xss-bot | `xss-bot.team<N>.sabanacorp.internal` | `bot.team<N>...` |
| filesrv (DMZ) | `filesrv.dmz.sabanacorp.internal` | `files.dmz...` |
| wiki (DMZ-VM) | `wiki.dmz.sabanacorp.internal` | `wiki-int.dmz...` |
| parking (DMZ) | `parking.dmz.sabanacorp.internal` | — |
| decoys (DMZ) | `<DECOY_NAME>.dmz.sabanacorp.internal` (`printer-01`, `admin-console`, `mail-old`, `backup-old`, `monitor-old`, `database-test`, ...) | `<profile>.dmz...` (`printer`, `admin`, ...) |
| lab resolver | `dns.sabanacorp.internal` → `10.200.0.1` | `gw.sabanacorp.internal` |

Mechanical derivation rule from container group name (what the generator implements), so adding a new service doesn't require deciding anything:

- `team<N>-<svc>` → `<svc>.team<N>.<LAB_DOMAIN>`
- `dmz-decoy-<x>` → `<x>.dmz.<LAB_DOMAIN>` (+ the narrative `DECOY_NAME` as canonical name)
- `dmz-<x>` → `<x>.dmz.<LAB_DOMAIN>`

Narrative aliases go in an explicit table inside `generate-dns-hosts.sh` (a bash associative array), not derived — they're CTF script decisions, not infrastructure.

**The first name in each row is canonical**: dnsmasq generates the PTR (reverse) with it, so a `nmap -sL 10.60.3.0/24` or `dig -x` from inside returns the pretty name. Deliberate flavor detail (see "Isolation").

### `snet-mgmt` is not published

No service from `snet-mgmt` (Monitor/Grafana, Provisioner, future jumpbox) receives a record. Not as a security control — real isolation is `iptables` on the gateway — but because publishing them gives away staff-plane recon for zero participant benefit. Staff gets there via the admin tunnel and by IP, or with a four-line local `/etc/hosts`.

## Chicken and egg: does `sed` disappear? (honest answer: barely)

This is the point where it's important to be explicit, because intuition ("with DNS I don't need IPs anymore")
is wrong here.

### What Today's `deploy_team_workload()` does

```
1. az container create team<N>-database
2. wait_for_ip team<N>-database            <- reads the IP (az container show, up to 5 min of retries)
3. sed -i 's|<DATABASE_IP>|10.60.N.4|' team<N>-webapp.yaml      (lab-azure.sh:271)
4. az container create team<N>-webapp
5. wait_for_ip team<N>-webapp
6. sed -i 's|<WEBAPP_IP>|10.60.N.5|' team<N>-xss-bot.yaml       (lab-azure.sh:277)
7. az container create team<N>-xss-bot
```

### What would happen with "pure" DNS (env vars with FQDN)

```
1. az container create team<N>-database
2. wait_for_ip team<N>-database            <- SAME. Can't register what you don't know.
3. az vm run-command invoke ... writes 10.60.N.4 database.teamN.<dom> to gateway   <- NEW
4. (wait for dnsmasq to reload)                                                    <- NEW
5. az container create team<N>-webapp (with DB_HOST=database.teamN.<dom> already in template)
6. ... same for xss-bot
```

**The only thing that really disappears is the placeholder `<DATABASE_IP>` in the YAML and the
`sed` line.** The `wait_for_ip` — which is 95% of the time and 100% of the fragility of that step — does not
disappear: the DNS record of the dependent can only exist *after* Azure assigns it
an IP. The chicken and egg doesn't break, it just moves: instead of "inject the IP into the
dependent's YAML" (local operation, instantaneous, no external dependencies, impossible to fail by
network) it becomes "register the IP in a third system" (`az vm run-command invoke`: 5-15 s of
round-trip, serialized per VM, and therefore **not parallelizable** — exactly the step that
`add-team-range` optimized).

And a new coupling appears at **runtime**, not just at deploy: Today `webapp` carries `database`'s IP
baked in and doesn't ask anyone anything. With FQDN, every reconnection of `webapp` to MySQL
goes through dnsmasq. If dnsmasq is down when `webapp` restarts (`restartPolicy: OnFailure`), that
team's Challenge 1 becomes unusable for a reason that today is impossible.

### What is really gained

One benefit, and it's real and documented: **decoupling the lifecycle**. With FQDN, recreating
`team7-database` with a different IP no longer forces redeploying `team7-webapp` — just re-register. That
is exactly step 3 of the `restore` that `docs/plans/observability-monitoring.md` proposes
("Always, at the end: re-resolve and inject the IPs of dependencies downstream") and makes the
`IPDrift` alert no longer critical. With low `local-ttl` (see config), propagation is
in seconds.

### Recommendation

**Container environment variables remain at IP. The `sed` is kept.** DNS is the
name layer for humans, tools, and navigation within the CTF, not the data plane of
the challenges.

Consequences of this decision, all deliberate:

- A total dnsmasq failure **doesn't break any challenge already deployed**. It's the property that makes
  the rest of this plan safe to implement a week before the event.
- Rollback is trivial and doesn't touch containers (see "Rollback").
- The new step 3 (register in dnsmasq) comes off the critical path of the deployment: can be done
  *after* deploying the entire team, in batch, in the sequential step, instead of interleaved
  between container and container.

Containers **do** receive `dnsConfig` pointing to the gateway (Phase 3): that's what allows
a participant who pivoted to `linux-server` to do `curl http://filesrv.dmz.sabanacorp.internal`
and to feel reconnaissance like a real corporate network. but what the challenge *needs*
to function (`DB_HOST`, `WEBAPP_BASE_URL`) remains an IP.

Only exception evaluated and **not recommended for the event**: `WEBAPP_BASE_URL` of the `xss-bot`
as FQDN, which would make Challenge 1 more realistic (the bot navigates to a domain, not an IP; cookies
have a real domain). It's tempting and is the case where FQDN adds game value, not just
convenience — but it makes DNS a prerequisite of the XSS challenge. Only consider if Phases 1-4
have been stable for weeks and there's margin to test it for real.

### Is `dnsConfig` supported in ACI?

Yes — `properties.dnsConfig` (`nameServers[]`, `searchDomains`, `options`) is part of the schema of
a container group and is designed precisely for container groups deployed in a VNet. It's
configured via YAML/ARM (`az container create --file`), **there is no equivalent flag on the command line**,
which aligns with the fact that this repo already deploys everything with `--file`. The `apiVersion:
2021-07-01` that the templates use is posterior to its introduction.

Two things that **need to be verified against reality before trusting it** (Phase 0, with a
test container and `az container exec ... cat /etc/resolv.conf`):

1. That when specifying custom `nameServers`, ACI **replaces** the default resolver instead of
   adding to it. That's the expected behavior, and it's the reason the design includes `168.63.129.16` as
   a second explicit nameserver: to not break outbound internet resolution for containers
   if dnsmasq doesn't respond.
2. That changing `dnsConfig` in an existing container group forces recreation (and thus a new
   IP). If that's the case — and it's likely — applying Phase 3 to already-deployed teams means
   running `add-team <N>` again, which already re-reads IPs and re-injects with `sed`, so it self-repairs.
   Document it to avoid discovering it during the event.

Docker image pulls from Docker Hub are done by the ACI host, **not** the container, so
`dnsConfig` can't break container startup by failing to resolve `index.docker.io`.
This is important and should be confirmed in Phase 0 by deploying a complete team with
`dnsConfig` and dnsmasq **deliberately stopped**.

## Resolution architecture

```
Participant's PC (Windows/Linux/macOS)
   │  DNS = 10.200.0.1, sabanacorp.internal      (only lab domain on Windows/macOS; see "Split-DNS")
   ▼  (through tunnel; requires 10.200.0.1/32 in client's AllowedIPs)
┌──────────────────────── vm-wg-gateway ────────────────────────┐
│  wg0 = 10.200.0.1/16   ◄── queries from VPN clients          │
│  eth0 = 10.10.0.4      ◄── queries from ACI containers       │
│                                                               │
│  dnsmasq                                                      │
│    hostsdir=/etc/dnsmasq.hosts.d/   (inotify, no reloads)    │
│      ├── dmz      (13 services + wiki on vm-wiki)             │
│      ├── teams    (4 records × N teams)                       │
│      └── infra    (dns./gw.)                                  │
│    local=/sabanacorp.internal/   → never forwards zone         │
│    no-resolv + server=168.63.129.16  → everything else to Azure│
└───────────────────────────────────────────────────────────────┘
   ▲                                        │
   │ dnsConfig.nameServers[0]=10.10.0.4     ▼ upstream
   │ dnsConfig.nameServers[1]=168.63.129.16   Azure DNS (168.63.129.16) → internet
ACI containers (snet-team<N>, snet-dmz-shared)
```

Two details that are not optional:

- **`10.10.0.4` must be a static IP.** Today `deploy_wg_gateway()` doesn't set it, and if the VM
  is recreated it could change — which would leave the `dnsConfig` of *all* containers pointing to
  nothing (with fallback to Azure DNS, or: the entire lab stops resolving names and nobody knows
  why). It's set with `--private-ip-address 10.10.0.4` in `az vm create`
  (`snet-wg-gateway` = `10.10.0.0/28`; `.0` is the network and `.1`-`.3` are reserved by Azure, so `.4` is
  the first usable, which is exactly what DHCP assigns today). With that, both `10.200.0.1` and
  `10.10.0.4` are design constants and need not be discovered at generation time.
- **The team client must route `10.200.0.1/32`.** Today `create_wg_team_peer()` passes
  `"10.60.<N>.0/24 10.50.0.0/24 10.51.0.0/24"`, and `create_wg_peer()` uses that same string for both
  `iptables` rules and the client's `AllowedIPs`. `10.200.0.1` is not in
  any of those CIDRs, so **today a team client can't even send a
  DNS packet to the gateway**: the WireGuard driver discards it on the client side (exactly
  the behavior documented in `wireguard-vpn-gateway.md`, "the client-side `AllowedIPs`
  is itself a filtering layer"). Need to separate the two lists: client's `AllowedIPs`
  = allowed CIDRs **+ `10.200.0.1/32`**; `iptables FORWARD` rules = only the CIDRs (traffic to the
  gateway itself is `INPUT`, not `FORWARD`, and doesn't need a new rule as long as the
  `INPUT` policy is `ACCEPT`). The `admin` peer already covers `10.200.0.1` because its
  `10.0.0.0/8` contains it.

## Zone write mechanism and parallelism

This is the real risk point of the plan, and it's the same one that forced peers
to remain sequential in `add_team_range()`.

### The general rule that must be documented

**All writes to `vm-wg-gateway` go in a sequential step.** It's not just about file corruption:
`az vm run-command invoke` executes through the VM's RunCommand extension, which
**is single-threaded per VM** — two concurrent invocations against the same machine either
serialize or fail with an operation-in-progress conflict. It's the same root cause of "Step 3
(sequential)" in the parallelism decision in `CLAUDE.md`; it's worth generalizing it there instead of
repeating it per case.

### Chosen mechanism

Three layers, each solving a different problem:

**1. Files per block in `hostsdir`, not a single shared file.**
`dnsmasq --hostsdir=/etc/dnsmasq.hosts.d` reads *all* files in the directory in
`/etc/hosts` format and — this is important — **watches them with inotify**: a new or modified file
is loaded automatically, without `SIGHUP` and without restarting the service. (Watch out for the trap: `SIGHUP`
to dnsmasq reloads `/etc/hosts` and `addn-hosts`, but **doesn't** re-read `/etc/dnsmasq.d/*.conf`; and
restarting dnsmasq in the middle of the event is exactly what we don't want. `hostsdir` avoids both.)
Ubuntu 22.04 comes with dnsmasq 2.86; `hostsdir` has existed since 2.75.

**Atomic write mandatory**: write to `/tmp/x` and `mv` to the final directory, so
inotify never sees a half-written file. A direct `cat > /etc/dnsmasq.hosts.d/teams` can
trigger the read with a truncated file.

**2. Parallel phase writes locally; only sequential phase touches the gateway.**
`deploy_team_workload()` already knows the IPs of its 4 containers (just read them with
`wait_for_ip`). Instead of sending them to the gateway right there — which would serialize the parallel phase
against the RunCommand extension — it writes a **file specific to that team** on local disk:
`yamls/generated/dns/team<N>.hosts`. Zero contention: each parallel job writes a different file, just like
today each one writes its own `team<N>-*.yaml`.

**3. One push per operation, not one per team.**
`sync_lab_dns()` does `cat yamls/generated/dns/*.hosts` → `yamls/generated/dns/lab.hosts`, sends it in
**one** `run-command` invocation (base64 inside the script, same pattern already
tested in `create_wiki_vm()`), and the remote script installs it atomically. It's called:

- at the end of `deploy_dmz()`
- at the end of `deploy_team()` (single-team path)
- in `add_team_range()`, **once**, between Step 2 (parallel) and Step 3 (peers)
- at the end of `create_wiki_vm()`
- on-demand with `./lab-azure.sh dns-sync`

Cost for a range of 100 teams: **one** invocation (~10 s), not 100. DNS doesn't change the
scaling curve of `add-team-range`; the bottleneck remains the peer loop.

Cheap extra protection: `flock` local on `yamls/generated/dns/.lock` in `sync_lab_dns()`, in case
someone calls it from two terminals someday.

### Why not alternatives

- **A single shared file on the gateway with append per team** (`>> /etc/dnsmasq.hosts.d/lab`):
  it's the pattern that already nearly bit the peers in `wg0.conf`. Remote read-modify-write,
  not idempotent (redeploying a team duplicates lines or leaves orphaned records with the old IP),
  and forces "delete team7's lines and add them back" logic with remote `sed`.
  Full file replacement > in-place editing, always.
- **One file per team on the gateway** (`/etc/dnsmasq.hosts.d/team<N>`): eliminates file
  corruption but **doesn't** eliminate the RunCommand bottleneck — still N sequential invocations.
  Rejected as the main path, but it's the natural fallback if the single push hits the script
  size limit (see "Scalability").
- **Gateway does a pull** (a systemd timer that queries `az container list`): requires giving it
  a Managed Identity with read permissions on the RG to a VM exposed to the internet.
  Expanding the surface of the only public host in the lab to save one `run-command` is a bad
  trade-off.

### The real source

The happy path uses local state (`yamls/generated/dns/*.hosts`), which is fast and already in
hand. But that state is lost if the operator switches machines, or becomes stale if someone
recreates a container manually. That's why `dns-sync --from-azure` rebuilds **all**
`team<N>.hosts` and `dmz.hosts` from `az container list` (one call) + the IP of `vm-wiki`,
and then pushes. It's the repair command, and also the one run before the event to
guarantee that the zone reflects Azure and not the operator's memory.

## Scalability to ~100 teams

| Metric | 20 teams | 100 teams | Comment |
|---|---|---|---|
| A records | 80 + 14 + 2 = 96 | 400 + 14 + 2 = 416 | 4 per team (`database`, `webapp`, `linux-server`, `xss-bot`) + DMZ (13 ACI + wiki) + infra |
| File lines | 96 | 416 | 1 line = 1 IP + canonical FQDN + aliases |
| Zone size | ~7 KB | ~30 KB | irrelevant for dnsmasq (reads `/etc/hosts` with hundreds of thousands of lines without breaking a sweat) |
| File load by dnsmasq | ms | ms | inotify, no restart, no cache loss |
| Local regeneration | <1 s | <1 s | concatenating already-existing files |
| Rebuild `--from-azure` | ~5 s | ~15-40 s | **one** `az container list` call with 400+ groups; may paginate — measure |
| `run-command` invocations for DNS | 1 | 1 | O(1), not O(N) — this is the whole point of the design |
| Query latency | <1 ms | <1 ms | resolution from memory |

The only hard limit that could appear is the **size of the `az vm run-command
invoke` script**: the zone is embedded in base64 within `--scripts`, or is ~30 KB → ~40 KB of base64
at 100 teams. Should pass easily, but need to **measure it with a synthetic zone of 100
teams before assuming it** (it's in the test plan). If it doesn't pass, the mitigation is free
thanks to `hostsdir`: split into `teams-001-025`, `teams-026-050`, ... (N/25 invocations, all
in the sequential step). Nothing else in the design changes.

A second scalability detail, which **isn't** about DNS but worth noting because it appears in the same
run: Step 3 of `add_team_range` (peers, sequential, ~10 s per team via `run-command`)
is ~17 minutes at 100 teams. DNS adds 10 s to that total. If that step ever becomes the
problem, the solution (batch M peers per invocation) is the same idea already applied here, and
should be done at the same time.

Also in `run-command` output: only the last ~4 KB of the message is read. The remote DNS script must print
**a short summary** (`OK <n> records`), never the zone.

## Resilience: what happens when DNS goes down

The question "does a container that can't resolve its DB become unusable?" has a one-word
answer thanks to the decision above: **no**, because its DB isn't in a name, it's in a
baked-in IP. That is the main mitigation and it's by design, not configuration.

The rest, by scenario:

| Scenario | Real Effect | Mitigation |
|---|---|---|
| dnsmasq dies (crash, OOM) | Names stop resolving. Challenges continue working (env vars = IP). Containers fall back to 2nd nameserver (`168.63.129.16`) → keep resolving internet, not lab | Drop-in systemd `Restart=always` / `RestartSec=2` (Ubuntu's `dnsmasq.service` **doesn't** have this) |
| `vm-wg-gateway` restarts | ~1-2 min without VPN **and** without DNS. Challenges stay up | `systemctl enable dnsmasq`; zone lives on disk (`/etc/dnsmasq.hosts.d/`), not in memory; `bind-dynamic` makes dnsmasq not depend on `wg0` existing at startup |
| `vm-wg-gateway` is completely lost | No lab from outside anyway (it's the only entry point). Containers inside the VNet keep talking via IP | Recreate with `deploy-wg-gateway` + `dns-sync --from-azure` (rebuilds zone from Azure, not from backup) |
| A container starts with dnsmasq down | Starts normally. Image pull doesn't use the container's DNS. Only loses names | 2nd nameserver + env vars on IP |
| Outbound internet for containers | **Changes**: Today they go straight to Azure DNS; with `dnsConfig` they go to dnsmasq, which forwards to `168.63.129.16` | `no-resolv` + explicit `server=168.63.129.16` in dnsmasq (mandatory: without `no-resolv`, dnsmasq would read `/etc/resolv.conf`, which on Ubuntu 22.04 points to `127.0.0.53` — **resolution loop with itself**) |
| dnsmasq responds slowly / partially | glibc resolver waits for `timeout` before trying 2nd nameserver | `options: "ndots:2 timeout:1 attempts:2"` in `dnsConfig` → at most ~2 s penalty, not 5 s default |
| A participant leaves tunnel up and gateway goes down | On Windows/macOS: nothing, only lab domain went through tunnel (NRPT/matchDomains). On Linux: may lose **all** DNS | Always deliver `DNS = 10.200.0.1, sabanacorp.internal` and document `wg-quick down` (see "Split-DNS") |

Security note that's part of resilience: dnsmasq listens on `eth0`, and `eth0` is the
NIC to which Azure NATes the gateway's **public IP**. An open resolver to the internet becomes
a DDoS amplifier in a matter of hours. Two layers: (a) the NSG `nsg-wg-gateway`
only allows UDP 51820 from the Internet — **never add a rule for 53 from the Internet**; (b)
explicit `INPUT` rules that only accept 53 from `wg0` and from `10.0.0.0/8` on `eth0`. Today the
`INPUT` policy is `ACCEPT` and those rules are no-ops, but they leave the intention documented and
survive a future `-P INPUT DROP`.

### Rollback

In order of increasing cost; the first two don't touch any containers:

1. **Shut down DNS**: `systemctl stop dnsmasq` on the gateway. Names are lost. **No
   challenge breaks.** It's the panic button during the event.
2. **Revert clients**: regenerate `.conf` with `CLIENT_DNS="1.1.1.1"` (`wg-team-peer
   <N>` per team, or a loop). Doesn't require touching the gateway or containers; just
   redistribute files.
3. **Revert containers**: leave `LAB_DNS_SERVER` empty (generators omit the
   `dnsConfig` block) and redeploy affected teams with `add-team <N>`. It's expensive (recreates
   containers, changes IPs) and **only necessary if `dnsConfig` turns out actively harmful** —
   with 2nd nameserver at `168.63.129.16`, a dead dnsmasq doesn't justify it.

That rollback is cheap is a direct consequence of not moving env vars to FQDN. If
"Phase 6" were done, step 3 would stop being optional and become mandatory and urgent.

## WireGuard client and split-DNS by operating system

Change in `create_wg_peer()`: `CLIENT_DNS="1.1.1.1"` → `CLIENT_DNS="10.200.0.1, ${LAB_DOMAIN}"`,
and client's `AllowedIPs` += `10.200.0.1/32`.

The resulting `.conf` for a team:

```ini
[Interface]
PrivateKey = ...
Address = 10.200.3.2/32
DNS = 10.200.0.1, sabanacorp.internal

[Peer]
PublicKey = ...
Endpoint = <ip-publica>:51820
AllowedIPs = 10.60.3.0/24, 10.50.0.0/24, 10.51.0.0/24, 10.200.0.1/32
PersistentKeepalive = 25
```

A single `DNS =` line produces **different behaviors per OS**, and it needs to be documented
because it determines what's promised to the participant:

**Windows (official WireGuard client, wireguard-nt) — real split-DNS.**
The second value translates to an **NRPT** (Name Resolution Policy Table) rule: only
queries ending in `sabanacorp.internal` are sent to `10.200.0.1`; the rest of the participant's DNS
keeps going to their usual resolver. That's the desired behavior and the reason for
including the domain. If the `.conf` had **only the IP**, the client would apply that DNS
globally and the participant would lose internet resolution if the gateway fails.
- Verification: `Get-DnsClientNrptPolicy`, `Resolve-DnsName webapp.team3.sabanacorp.internal`.
- **Trap to document**: `nslookup` **doesn't respect NRPT** — talks directly to the adapter's
  default server, so it will say "doesn't exist" even if everything is fine. On Windows verify
  with `Resolve-DnsName`, never with `nslookup`.

**Linux (`wg-quick` + `resolvconf`/`systemd-resolved`) — no real split-DNS.**
`wg-quick` interprets non-IP values in `DNS =` as **search domains**, not routing rules. In practice,
with systemd-resolved's `resolvconf` shim, `wg0` ends up with
`DNS=10.200.0.1` and `Domains=sabanacorp.internal`, and **much (or all) of the device's DNS traffic
goes through the gateway while the tunnel is up**. That's why dnsmasq **must**
forward upstream: if not, the participant loses internet by name as soon as they connect and
the diagnosis ("I lost internet") arrives as a support incident.
- Real split optional, for those who want it: after bringing up the tunnel,
  `sudo resolvectl domain wg0 '~sabanacorp.internal'` (the `~` makes it a *routing domain*, and
  only that domain goes through the tunnel).
- **`wg-quick` fails with `resolvconf: command not found`** on minimal installations and on WSL2 (which
  also regenerates `/etc/resolv.conf` on its own). Documented solution:
  `sudo apt install openresolv`; alternative without changing anything: delete the `DNS =` line from `.conf` and
  use `dig @10.200.0.1 <name>` / `curl --resolve` when needed.

**macOS.**
- Official app (App Store): uses `NEDNSSettings` with *match domains* → split behavior
  equivalent to Windows.
- Homebrew `wg-quick`: uses `networksetup -setdnsservers` on all network services →
  global DNS while tunnel is up, restored when brought down. Same as Linux.

**Android/iOS** (official app): support `DNS = ip, domain` with match domains, like Windows. Not
a case foreseen for participants, mentioned for completeness.

### What is delivered to the participant

The `.conf` alone is not sufficient. Along with it, a
`yamls/generated/wg-clients/team<N>-README.md` (new template) is generated with:

1. How to import the `.conf` on their OS.
2. **The FQDN table for their own team** (the 4 services) + those of the DMZ. It's the "Sabana Corp services sheet"
   — replaces the IP list, and is game material, not just documentation.
3. The verification command for their OS (`Resolve-DnsName` on Windows, `getent hosts` /
   `resolvectl query` on Linux, `dscacheutil -q host -a name` on macOS).
4. The `openresolv` note for Linux/WSL.
5. An explicit line: *"a name resolving doesn't mean you can reach it"* — avoids
   support tickets like "DNS is broken" when what's happening is they're trying to
   access another team's services.

## Isolation: resolving is not reaching

Access control **doesn't change at all**: it's still `iptables` on `vm-wg-gateway`, one
`FORWARD` rule per peer and allowed CIDR with `DROP` policy, validated end-to-end on
2026-08-08 (including an actual bypass attempt by editing client `AllowedIPs`). DNS is
a naming service, not a boundary.

**Recommendation: flat zone, no split-horizon. Everyone resolves everything (except
`snet-mgmt`, which simply isn't published).**

Reasons, in order of weight:

1. **It's CTF flavor, not a leak.** Discovering that `webapp.team7.sabanacorp.internal` exists, or
   that `dig -x 10.50.0.9` returns `printer-01.dmz`, is reconnaissance — exactly what a
   pentester does on a real corporate network, and exactly the kind of thing the DMZ with
   decoys is designed to reward. Plus the scheme is guessable in three seconds
   (`team<N>`), so hiding it hides nothing.
2. **The limit already exists and is tested.** A team that resolves `webapp.team7` and does `curl`
   hits a timeout on the gateway's `DROP`. That contract ("I resolve, I don't reach") is easy to
   explain, easy to test (it's in the test plan as a negative test) and doesn't depend on
   DNS behaving correctly.
3. **dnsmasq doesn't have views.** Implementing split-horizon would require one instance per team
   (100 processes, 100 listening IPs or 100 ports, and one routing rule per peer), or
   switching to CoreDNS with the `view` plugin. That's multiplying by 100 the complexity of the component
   that — if it fails — shuts down the event's names, to protect information the
   participant can guess. Bad trade-off.
4. **Complexity in the naming layer is what causes failures.** One file, one process, one
   source of truth. Being able to say "`cat /etc/dnsmasq.hosts.d/teams`" and see the complete
   state is worth more during the event than any refinement.

The only restriction actually applied is publication, not resolution: **`snet-mgmt` doesn't
enter the zone** (see "Naming scheme").

## File-by-file changes

### `yamls/wg-gateway/cloud-init.yaml`

- `packages:` += `dnsmasq`.
- `write_files:` += `/etc/dnsmasq.d/00-lab.conf`:

```
# Listen only on lab interfaces. bind-dynamic (not bind-interfaces): tolerates wg0
# appearing/disappearing and avoids conflicting with systemd-resolved stub on 127.0.0.53:53.
bind-dynamic
interface=wg0
interface=eth0

# Explicit upstream. no-resolv is MANDATORY: without it, dnsmasq would read /etc/resolv.conf, which on
# Ubuntu 22.04 points to 127.0.0.53 (systemd-resolved) -> resolution loop with itself.
no-resolv
server=168.63.129.16

# Lab zone never forwards upstream: Azure DNS doesn't know it, and without this every
# nonexistent lab name goes to the internet and takes time.
local=/sabanacorp.internal/
domain=sabanacorp.internal
expand-hosts
domain-needed
bogus-priv

# Lab records: /etc/hosts format, one file per block, reloaded by inotify (without
# SIGHUP and without restarting the service -- SIGHUP doesn't re-read /etc/dnsmasq.d/*.conf, hostsdir does).
hostsdir=/etc/dnsmasq.hosts.d

# Short TTL: if a container is recreated with a different IP, correction propagates in seconds.
local-ttl=10
cache-size=1000
log-facility=/var/log/dnsmasq.log
#log-queries   # enable only for debugging; during event generates too much noise
```

- `write_files:` += `/etc/dnsmasq.hosts.d/.keep` (the directory **must exist** before
  dnsmasq starts: if `hostsdir` points to something nonexistent, dnsmasq fails to start).
- `write_files:` += `/etc/systemd/system/dnsmasq.service.d/10-restart.conf` with
  `[Service]\nRestart=always\nRestartSec=2`.
- `runcmd:` += `INPUT` rules for 53 (document the intent; no-ops while `INPUT` is
  `ACCEPT`):
  `iptables -A INPUT -i wg0 -p udp --dport 53 -j ACCEPT` (+ tcp), and
  `iptables -A INPUT -i eth0 -s 10.0.0.0/8 -p udp --dport 53 -j ACCEPT` (+ tcp), before the
  `netfilter-persistent save` that already exists.
- `runcmd:` += `systemctl enable --now dnsmasq`.
- Add to the header comment the note about why `no-resolv`.

### `yamls/wg-gateway/remote/apply-dns.sh.tpl` (new)

Same pattern as `add-peer.sh.tpl`: `envsubst` template with whitelisted variables
(`${ZONE_NAME}`, `${ZONE_B64}`), resolved **locally** and sent complete as a single string to
`az vm run-command invoke`. Does:

1. `echo "${ZONE_B64}" | base64 -d > /tmp/lab.hosts.$$`
2. Minimal validation before installing (not empty and each line starts with IP) — a
   corrupted file must not reach `hostsdir`.
3. **Atomic** installation: `install -m 644 /tmp/lab.hosts.$$ /etc/dnsmasq.hosts.d/${ZONE_NAME}`
   (or `mv`), never direct `cat >` to the destination.
4. Short wait + verification that dnsmasq responds: `dig +short @127.0.0.1 <a-name>`.
   If not responding, `systemctl restart dnsmasq` as safety net and retry.
5. Short and parseable output (`OK records=<n>`), because `run-command` truncates the message.

Idempotent by construction: replaces the complete file, doesn't edit.

### `yamls/generate-dns-hosts.sh` (new)

Follows the convention of other generators (`set -euo pipefail`, environment validation, writes
to `generated/`, prints what it created). Two modes:

- **Per team** (`generate-dns-hosts.sh team <N> <ip_db> <ip_webapp> <ip_linux> <ip_bot>`) →
  writes `generated/dns/team<N>.hosts`. Called by `deploy_team_workload()` with IPs already
  on hand; no Azure calls, safe in parallel.
- **DMZ** (`generate-dns-hosts.sh dmz`) → writes `generated/dns/dmz.hosts` + `infra.hosts`,
  reading `az container list` (the 13 DMZ ones) and `az vm list-ip-addresses -n vm-wiki`.
- **Rebuild** (`generate-dns-hosts.sh all-from-azure`) → regenerates **all**
  `team<N>.hosts` + `dmz.hosts` with a single `az container list`, deriving team and service from the
  container group name.

Contains the narrative aliases table (associative array) and the mechanical derivation rule. Example output:

```
# generated by yamls/generate-dns-hosts.sh -- do not edit by hand
10.50.0.6   filesrv.dmz.sabanacorp.internal filesrv.dmz files.dmz.sabanacorp.internal
10.51.0.4   wiki.dmz.sabanacorp.internal wiki.dmz wiki-int.dmz.sabanacorp.internal
10.50.0.9   printer-01.dmz.sabanacorp.internal printer.dmz.sabanacorp.internal
10.60.3.4   database.team3.sabanacorp.internal db.team3.sabanacorp.internal
10.60.3.5   webapp.team3.sabanacorp.internal helpdesk.team3.sabanacorp.internal
10.60.3.6   linux-server.team3.sabanacorp.internal pivot.team3.sabanacorp.internal
10.60.3.7   xss-bot.team3.sabanacorp.internal bot.team3.sabanacorp.internal
10.200.0.1  dns.sabanacorp.internal gw.sabanacorp.internal
```

Add `generated/dns/` to `yamls/`'s `.gitignore` — already covered by `generated/`.

### `yamls/templates/team-*.yaml.tpl` (all 4) and `dmz-*.yaml.tpl` (all 14)

New block under `properties:`, at the same level as `containers`/`osType`/`subnetIds`:

```yaml
  # DNSCONFIG-BEGIN -- generator removes it if LAB_DNS_SERVER is empty (lab without gateway).
  # 2nd nameserver intentional: if dnsmasq doesn't respond, container still resolves internet
  # via Azure DNS. Lab names stop resolving, but no challenge breaks because
  # DB_HOST/WEBAPP_BASE_URL stay as IPs (see docs/plans/internal-dns.md).
  dnsConfig:
    nameServers:
      - "${LAB_DNS_SERVER}"
      - "168.63.129.16"
    searchDomains: "team${TEAM}.${LAB_DOMAIN} dmz.${LAB_DOMAIN} ${LAB_DOMAIN}"
    options: "ndots:2 timeout:1 attempts:2"
  # DNSCONFIG-END
```

(in `dmz-*` templates, `searchDomains` is `"dmz.${LAB_DOMAIN} ${LAB_DOMAIN}"`).

Desirable side effect of `searchDomains`: inside a `team3` container, `curl
http://webapp` resolves to **its own** webapp, and `curl http://filesrv` to the DMZ. For the
participant who just pivoted to `linux-server`, that's the difference between "a network" and "a
list of IPs".

**`<DATABASE_IP>` / `<WEBAPP_IP>` stay as they are.** Don't touch them (see "Chicken and egg").

### `yamls/generate-team.sh` and `yamls/generate-dmz.sh`

- Add `LAB_DOMAIN` and `LAB_DNS_SERVER` to the `export` and `VARS` whitelist for `envsubst`.
- After `envsubst`, if `LAB_DNS_SERVER` is empty: `sed -i '/DNSCONFIG-BEGIN/,/DNSCONFIG-END/d'`
  on the generated file. `envsubst` doesn't understand conditionals; the block with sentinels is the
  simplest way to keep the "no gateway" flow working. This is what keeps
  `./lab-azure.sh test [N]` alive (which intentionally doesn't deploy the gateway).
- Update `generate-team.sh`'s header comment (explicitly mention what stays
  unresolved and why).

### `yamls/templates/wg-client.conf.tpl`

- The `DNS = ${CLIENT_DNS}` line doesn't change in form, just in content (filled by
  `create_wg_peer`).
- Add to the header comment block the explanation of split-DNS by OS (summary of 4-5
  lines + pointer to this document), and the note that `10.200.0.1/32` in `AllowedIPs` is what
  enables lab DNS to work.

### `yamls/templates/wg-client-readme.md.tpl` (new) and `yamls/generate-wg-client.sh`

New template with the participant deliverable (see "What is delivered"). `generate-wg-client.sh`
renders both files (`.conf` + `README.md`) with the same variables + `LAB_DOMAIN` and the
team number.

### `yamls/templates/wiki-vm-compose.yml.tpl`

`APP_URL: "http://wiki-int.empresa.local"` → `"http://wiki.dmz.${LAB_DOMAIN}"`. It's a real
behavior change, not cosmetic: BookStack builds its absolute links with `APP_URL`, so
today any redirect or generated link points to a name that doesn't resolve anywhere.
`generate-wiki-vm.sh` must export `LAB_DOMAIN`.

### `lab-azure.sh`

New variables (at the top, next to `RG`/`VNET`):
```bash
LAB_DOMAIN="${LAB_DOMAIN:-sabanacorp.internal}"
WG_GW_PRIVATE_IP="10.10.0.4"   # static: set by deploy_wg_gateway; see docs/plans/internal-dns.md
WG_GW_TUNNEL_IP="10.200.0.1"   # set by yamls/wg-gateway/cloud-init.yaml
DNS_DIR="${YAMLS_DIR}/generated/dns"
```

**New** functions:
- `lab_dns_server()` — returns `WG_GW_PRIVATE_IP` if `vm-wg-gateway` exists, empty string if not.
  Determines whether templates include `dnsConfig`.
- `sync_lab_dns()` — concatenates `${DNS_DIR}/*.hosts`, renders `apply-dns.sh.tpl` with `envsubst`,
  sends it in **one** `run-command` invocation, validates output. Guarded and non-blocking
  (same spirit as `create_wg_team_peer`): if `vm-wg-gateway` doesn't exist, warns and continues — a
  lab without gateway must continue deploying normally.
- `rebuild_lab_dns_from_azure()` — calls `generate-dns-hosts.sh all-from-azure` + `sync_lab_dns`.

**Modified** functions:
- `deploy_wg_gateway()` — `--private-ip-address 10.10.0.4` in `az vm create`; wait loop also
  checks `systemctl is-active dnsmasq`; at the end, `sync_lab_dns` (so a recreated gateway
  recovers the zone without manual steps).
- `create_wg_peer()` — `CLIENT_DNS="${WG_GW_TUNNEL_IP}, ${LAB_DOMAIN}"`; and separate the two CIDR
  lists: `CLIENT_ALLOWED_IPS` = `allowed_cidrs` + `${WG_GW_TUNNEL_IP}/32`, while what's
  passed to `add-peer.sh.tpl` (the `FORWARD` rules) remains only `allowed_cidrs`.
- `create_wg_team_peer()` — no changes to allowed CIDRs (DNS `/32` is added by
  `create_wg_peer`).
- `deploy_team_workload()` — exports `LAB_DOMAIN` and `LAB_DNS_SERVER` when calling
  `generate-team.sh`; and at the end, after deploying the 4, calls `generate-dns-hosts.sh team <N>
  ...` with the IPs it already has. **Local write only** — no `run-command` here. This is the parallel phase.
  (Also requires capturing IPs of `linux-server` and `xss-bot`, which today are discarded with
  `>/dev/null`.)
- `deploy_team()` — `sync_lab_dns` after `create_wg_team_peer`.
- `deploy_dmz()` — exports variables to the generator; at the end, `generate-dns-hosts.sh dmz` +
  `sync_lab_dns`.
- `create_wiki_vm()` — adds `vm-wiki` to `infra`/`dmz.hosts` + `sync_lab_dns` (it's the
  `wiki.dmz` record, which lives in a VM and doesn't come from `az container list`).
- `add_team_range()` — **New Step 2.5, sequential, between workloads and peers**: single
  `sync_lab_dns`. Update the function's long comment to explain why DNS is
  O(1) and why it goes in a sequential step (RunCommand is single-threaded per VM).
- `status()` — in the "WireGuard Gateway" section, add dnsmasq status and record count:
  `systemctl is-active dnsmasq; wc -l /etc/dnsmasq.hosts.d/*` via `run-command` (single
  invocation, leveraging the one already done for `wg show wg0`).
- Entrypoint: new subcommands `dns-sync` (with `--from-azure` flag) and `dns-check <fqdn>`
  (resolves from gateway and compares to actual Azure IP — the check run before
  opening the event). Update the `usage` and script header comment.

### `CLAUDE.md`

- Commands: `dns-sync`, `dns-check`.
- New section "Design decision: internal DNS with dnsmasq on the gateway", with a summary of
  this document: `.internal` domain (and why not `.local`), flat zone without split-horizon, and
  — most important for whoever comes next — **that env vars remain as IPs intentionally**.
  Without that sentence, the next person to touch `team-webapp.yaml.tpl` will "fix" the `<DATABASE_IP>`
  by putting an FQDN and will make DNS a hard dependency of the challenges.
- Generalize the parallelism section: the rule isn't "peers are sequential", it's **"all
  writes to `vm-wg-gateway` go in a sequential step"**, because `az vm run-command invoke`
  is single-threaded per VM.
- "Target network architecture": `snet-wg-gateway` becomes also the lab's DNS, with static
  private IP `10.10.0.4`.

### `yamls/README.md`

- Section on dnsmasq/hostsdir and the `generate-dns-hosts.sh` → `sync_lab_dns` flow.
- Update "Deployment order and IP resolution": still valid as-is, and **explain why
  it remains valid even with DNS** (that's the question everyone reading both sections will have).
- "Known gaps / pending": add DNS status.

### `docs/plans/network-segmentation-nsgs.md`

New note below the matrix: if NSGs are ever applied, **`snet-team*` and `snet-dmz-*` must
be able to reach `snet-wg-gateway` on UDP/TCP 53**. The current matrix leaves that column blank
("out of scope"), which today is correct but would become a silent DNS cutoff for
all containers. Same warning for `nsg-wg-gateway`: its current comment says it's
"deliberately more restrictive than the default"; if someone materializes that intent with a
`DenyVnetInBound`, need to add an `allow-dns-inbound` rule first (53 from `VirtualNetwork`).

### `docs/plans/observability-monitoring.md`

- The `IPDrift` alert **remains necessary** (env vars stay on IP) and now has a
  sibling: compare DNS record against actual Azure IP (what `dns-check` does).
- New `DnsDown` alert: probes TCP/UDP 53 to `10.10.0.4`. Medium severity, not critical —
  no challenge breaks, but names stop working.

### `README.md` (root)

Update "Current status" and usage flow with the new subcommands.

## Implementation phases

Each phase is verifiable on its own and **reversible without touching the previous one**. The order is chosen
so risk grows monotonically: touch the gateway, then the clients (rollback =
regenerate a file), and only at the end the containers (rollback = redeploy).

**Phase 0 — Verify assumptions (half day, no production code written).**
Four unknowns that if they fail change the design, so test them first:
1. `dnsConfig` actually applies to a container group in VNet → deploy **one** test container
   with `dnsConfig` pointing to `1.1.1.1` and `az container exec ... cat /etc/resolv.conf`.
2. Image pull doesn't depend on container's `dnsConfig` → same container with a
   `nameServers` that doesn't exist; must start normally.
3. `az container list --query "[].{n:name,ip:ipAddress.ip}"` returns the IP (repo already knows
   `instanceView` **doesn't** come populated in `list`; `ipAddress` is another property, but confirm it —
   `--from-azure` depends on it).
4. Two `az vm run-command invoke` concurrently against the same VM: confirm they fail or
   serialize. Confirms the "sequential writes" rule and closes the race condition risk.

**Phase 1 — dnsmasq on the gateway, no clients or containers yet.**
`cloud-init.yaml`, `apply-dns.sh.tpl`, `generate-dns-hosts.sh`, `sync_lab_dns()`, subcommand
`dns-sync`. Testable **entirely from the gateway** (`dig @127.0.0.1`). No one else uses it yet;
impact on existing lab: zero. Requires recreating `vm-wg-gateway` (or applying cloud-init manually
via `run-command` on the running VM, which is preferable if teams already have tunnel delivered —
recreating the VM invalidates all `.conf` files).

**Phase 2 — VPN clients.**
`CLIENT_DNS`, `10.200.0.1/32` in `AllowedIPs`, `wg-client.conf.tpl`, participant README.
Testable from operator's PC with `admin.conf` and `team1.conf`, on Linux and Windows.
Rollback: regenerate `.conf`. Doesn't touch any containers.

**Phase 3 — `dnsConfig` in containers.**
Templates + generators + `lab_dns_server()`. Test first with **one new team only**
(`add-team 3`) before touching anything else, including test with dnsmasq deliberately stopped.

**Phase 4 — Integration in the lifecycle.**
`deploy_team_workload`, `deploy_dmz`, `add_team_range` (Step 2.5), `create_wiki_vm`, `status`,
`dns-check`. This is where behavior is validated with real parallelism (`add-team-range 4 8 4`).

**Phase 5 — Documentation.**
`CLAUDE.md`, `yamls/README.md`, `README.md`, cross-notes in the other two plans. Comes at the end
intentionally: document what was measured, not what was designed.

**Phase 6 — NOT executed before the event: env vars to FQDN.**
Left documented here so the decision is explicit and not made by accident. Re-evaluate only
when the `restore` subcommand from `docs/plans/observability-monitoring.md` exists, which is where the
benefit (not redeploying dependents) starts paying for the risk.

## Test plan

### From the gateway (Phase 1)

```bash
az vm run-command invoke -g rg-ctf-semana-ingenieria-test -n vm-wg-gateway --command-id RunShellScript \
  --scripts "systemctl is-active dnsmasq; ss -lunp | grep :53; dnsmasq --test; \
             dig +short @127.0.0.1 webapp.team1.sabanacorp.internal; \
             dig +short @127.0.0.1 filesrv.dmz.sabanacorp.internal; \
             dig +short @127.0.0.1 -x 10.50.0.6; \
             dig +short @127.0.0.1 www.google.com" \
  --query "value[0].message" -o tsv | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}'
```
Validates at once: process alive, listening where it should (`wg0`/`eth0`, **not** on `127.0.0.53`),
config syntactically correct, lab zone, PTR, and **forwarding to internet** (if the last
fails, there's a loop with systemd-resolved or missing `no-resolv`).

### From a container (Phase 3)

```bash
az container exec -g rg-ctf-semana-ingenieria-test -n team3-linux-server --exec-command "/bin/sh"
# inside:
cat /etc/resolv.conf          # nameserver 10.10.0.4 + 168.63.129.16 + search team3... dmz... 
getent hosts webapp.team3.sabanacorp.internal
getent hosts filesrv          # search domain: must resolve to filesrv.dmz.<dom>
getent hosts webapp           # must resolve to ITS OWN webapp, not another team's
```
`getent hosts` instead of `dig`/`nslookup`: challenge images don't come with `dnsutils`, but they do
have glibc. Checking `/etc/resolv.conf` is what proves `dnsConfig` actually applied.

### From the participant's PC over VPN — Linux (Phase 2)

```bash
sudo wg-quick up ./yamls/generated/wg-clients/team1.conf
resolvectl status wg0                    # DNS Servers: 10.200.0.1 / Domains: sabanacorp.internal
getent hosts webapp.team1.sabanacorp.internal
dig @10.200.0.1 webapp.team1.sabanacorp.internal   # direct test, bypassing the OS stack
curl -s -o /dev/null -w '%{http_code}\n' http://webapp.team1.sabanacorp.internal   # 302
curl -s -o /dev/null -w '%{http_code}\n' http://filesrv.dmz.sabanacorp.internal:8080  # 200
sudo wg-quick down ./yamls/generated/wg-clients/team1.conf
getent hosts webapp.team1.sabanacorp.internal      # must NOT resolve now (DNS restored)
```

### From the participant's PC over VPN — Windows (Phase 2)

```powershell
Get-DnsClientNrptPolicy | Where-Object {$_.Namespace -like "*sabanacorp*"}   # rule present
Resolve-DnsName webapp.team1.sabanacorp.internal    # do NOT use nslookup: it ignores NRPT
Invoke-WebRequest http://webapp.team1.sabanacorp.internal -UseBasicParsing
Resolve-DnsName www.google.com                      # still resolves through its normal DNS
```
Last line = the proof that split-DNS **is split** and not a global hijack.

### Key negative test: resolving ≠ reaching

```bash
sudo wg-quick up ./yamls/generated/wg-clients/team1.conf
getent hosts webapp.team2.sabanacorp.internal            # YES resolves (by design)
curl -s --max-time 5 http://webapp.team2.sabanacorp.internal   # MUST timeout
# confirm on gateway that DROP counter went up, same as validation on 2026-08-08:
az vm run-command invoke ... --scripts "iptables -L FORWARD -v -n"
```
This is the test that documents the security model; without it, "DNS shows everything" sounds like
a leak instead of a decision.

### Resilience (Phase 3, before calling the plan good)

```bash
# 1. dnsmasq dies -> challenges stay alive
az vm run-command invoke ... --scripts "systemctl stop dnsmasq"
curl http://<ip-webapp-team1>/          # 302: challenge still works by IP
az container exec -n team1-webapp ...   # webapp still talks to its DB (baked-in IP)
az vm run-command invoke ... --scripts "systemctl start dnsmasq"

# 2. Automatic restart
az vm run-command invoke ... --scripts "pkill -9 dnsmasq; sleep 5; systemctl is-active dnsmasq"  # active

# 3. Gateway reboot (never tested a real reboot -- open risk in
#    wireguard-vpn-gateway.md; this is the chance to close it for wg0 and dnsmasq together)
az vm restart -g ... -n vm-wg-gateway
# after startup: wg0 active, dnsmasq active, zone intact, tunnel reconnects

# 4. New container with dnsmasq down
az vm run-command invoke ... --scripts "systemctl stop dnsmasq"
./lab-azure.sh add-team 9      # must complete (with warning), all 4 containers Running
```

### Scale (before trusting 100 teams)

Generate a synthetic zone for 100 teams (416 records) without deploying anything, push it and measure:
size of `run-command` script (passes the limit?), time to push, dnsmasq load time, `dig` latency. If push
doesn't pass, split into 25-record blocks in `hostsdir`.

### End-to-end event test

`add-team-range 4 8 4` (real parallelism) → `dns-check` of the 20 resulting names → connect
with `team5.conf` from Windows and Linux → resolve and reach own 4 + DMZ ones →
resolve but **cannot** reach `team6`'s.

## Risks and mitigation

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | `dnsConfig` doesn't behave as expected in ACI+VNet | Phase 3 unviable; DNS would only work for VPN clients (already 80% of the value) | Phase 0 tests it with one container before touching 18 templates |
| 2 | Gateway's private IP changes when VM is recreated | **All** containers point to nonexistent DNS | Static `--private-ip-address 10.10.0.4` + constant in `lab-azure.sh` |
| 3 | Team client can't talk to `10.200.0.1` | DNS "doesn't work" only for teams, and the symptom (silence, no log on gateway) is misleading because discard happens in client kernel itself | `10.200.0.1/32` in `AllowedIPs`; explicitly tested in Phase 2 |
| 4 | dnsmasq ↔ systemd-resolved loop | dnsmasq can't resolve anything external; cascading timeouts | `no-resolv` + `server=168.63.129.16`; tested with `dig www.google.com` |
| 5 | dnsmasq won't start due to port 53 conflict | Phase 1 blocked | `bind-dynamic` + explicit `interface=`; verify with `ss -lunp` |
| 6 | `hostsdir` doesn't exist at startup | dnsmasq won't start | Create directory in `write_files` (`.keep`) |
| 7 | Non-atomic write → inotify reads half-written file | Corrupted zone, names disappear randomly | `install`/`mv` from `/tmp`, never direct `cat >` to destination |
| 8 | Two concurrent writes to gateway | RunCommand conflict; `add-team-range` failure | All writes in sequential steps; local `flock` |
| 9 | `run-command` script exceeds size limit at 100 teams | `dns-sync` fails right when most needed | Measure in scale test; split into 25-record blocks (free with `hostsdir`) |
| 10 | `.local` and mDNS | Intermittent resolution on macOS/Linux, impossible to diagnose during event | `.internal` domain |
| 11 | Linux/WSL without `openresolv` → `wg-quick` fails | Participant can't even bring up tunnel | Documented in client README + fallback (delete `DNS =` line) |
| 12 | Linux participant loses all DNS if gateway goes down with tunnel up | Support incidents during event | dnsmasq forwards to internet; document `wg-quick down`; `resolvectl domain wg0 '~domain'` as optional split |
| 13 | Open resolver to internet (DDoS amplification) | Gateway becomes attack participant; possible Azure block | NSG allows only 51820 from Internet + `INPUT` port 53 limited to `wg0` and `10.0.0.0/8` |
| 14 | Someone "fixes" `<DATABASE_IP>` by putting FQDN | DNS becomes hard dependency of challenges without decision | Explicit comment in templates + section in `CLAUDE.md` |
| 15 | Local zone becomes stale vs Azure | Names point to dead IPs; worse than no names | `dns-sync --from-azure` + `dns-check` in pre-event checklist |
| 16 | Recreating `vm-wg-gateway` to apply cloud-init invalidates all delivered `.conf` files | All teams get disconnected | If tunnels already delivered, apply dnsmasq config via `run-command` on running VM instead of recreate; cloud-init for next fresh gateway (same pattern used to fix `RELATED,ESTABLISHED` bug) |

## Acceptance criteria

1. `dig @127.0.0.1` on the gateway resolves one team service, one DMZ service, a PTR, and an
   internet name.
2. A newly deployed container shows `10.10.0.4` and `168.63.129.16` in `/etc/resolv.conf`, and
   `getent hosts webapp` resolves to **its own** webapp via search domain.
3. From PC with `team1.conf`: `curl http://webapp.team1.sabanacorp.internal` returns 302 and
   `http://filesrv.dmz.sabanacorp.internal:8080` returns 200, on Linux **and** Windows.
4. On Windows, `Get-DnsClientNrptPolicy` shows the lab domain rule and `Resolve-DnsName
   www.google.com` still uses the participant's DNS (split-DNS confirmed).
5. `webapp.team2...` resolves from `team1.conf` but `curl` times out and gateway's `DROP`
   counter increases.
6. With `systemctl stop dnsmasq`: `curl` by IP to webapp still 302, `webapp` still talks to
   its DB, and `add-team <N>` completes without error (with warning).
7. After `az vm restart` of gateway: `wg0` and dnsmasq active, zone intact, tunnel reconnects.
8. `add-team-range 4 8 4` completes without RunCommand errors and the 20 resulting names pass
   `dns-check`.
9. A synthetic zone for 100 teams (416 records) is pushed in one invocation and `dig`
   responds in <5 ms.
10. `./lab-azure.sh test 1` (without gateway) still works: generated YAML **don't** have
    `dnsConfig` block.
11. `status` shows dnsmasq status and record count.
12. `CLAUDE.md` documents that env vars stay on IP **and why**.

## Open / not yet decided

- **DNSSEC / DoT to upstream**: unnecessary (upstream is Azure platform via a
  link-local address). Don't implement.
- **SRV records / wildcards** (`*.team3` → webapp): tempting for "corporate" flavor, but
  facilitates accidental fingerprinting and nobody asked for it. Out for now.
- **`log-queries` during event**: would be a free telemetry source on what each team is
  enumerating (interesting for staff and scoreboard), but generates much noise
  and log rotation needs deciding. Fits better as an entry in
  `docs/plans/observability-monitoring.md` than here.
- **Names for CTFd / Provisioner / Monitor**: will be defined when they exist. The derivation rule
  already covers them if they live in DMZ; if in `snet-mgmt`, not published (see
  "Naming scheme") — except CTFd, which probably needs a name since participants must reach it.
  Decide when implemented.
- **DHCP / dynamic registration**: dnsmasq also does DHCP, but on Azure DHCP is
  platform-managed. Doesn't apply; mentioned only so nobody tries it.
- **Second resolver for high availability**: not worth it. If `vm-wg-gateway` goes down, there's no
  lab entry; a second DNS would resolve names nobody can reach.

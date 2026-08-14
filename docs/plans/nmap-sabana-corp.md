# Plan: `nmap-sabana-corp` (network discovery tool for participants)

## Status

**Design, not implemented — no code, no npm package, no changes to Azure yet.** This document decides architecture; implementation is a separate, subsequent effort.

What this plan **assumes already exists and is validated** (does not re-validate, only uses):

- `vm-wg-gateway` + tunnels per team, `AllowedIPs` = `10.60.<N>.0/24, 10.50.0.0/24,
  10.51.0.0/24, 10.200.0.1/32`, real access control via `iptables` — validated 2026-08-08
  (`docs/plans/wireguard-vpn-gateway.md`).
- dnsmasq on gateway, flat zone `sabanacorp.internal`, resolver reachable at `10.200.0.1`
  from any tunnel — validated 2026-08-10 (`docs/plans/internal-dns.md`).
- Standing caveat, **permanent by design**: some hosts WITH DNS records and some WITHOUT
  (deployed before DNS migration). See "The mixed case".

Three **unverified** assumptions on which the design depends, and which must be measured before writing production code (Phase 0, same convention as `internal-dns.md`):

1. That dnsmasq responds with **PTR** for `hostsdir` records when queried directly
   (`dig -x 10.60.1.4 @10.200.0.1`) from a team tunnel. The entire names layer of the tool depends on this.
2. What a **closed** port on a live ACI container returns (RST → `ECONNREFUSED`, or discard
   → timeout). Determines whether "closed" is a useful signal of host life or not.
3. **Conntrack pressure on the gateway** with N teams scanning simultaneously. This is the real risk of
   this plan and is developed in "What breaks first".

## Problem

Participants should discover what exists in their environment when starting a challenge, rather than being given a list of services. This is the right posture for a CTF — reconnaissance is part of the game — but today it's not viable:

- A real `nmap` against `10.0.0.0/8` is 16.7M addresses: hours. The lab lasts an afternoon.
- An `nmap` against the correct scope requires participants to know their scope, which today
  is only written inside the WireGuard `.conf` and nobody reads.
- nmap **is not installed** on most student laptops, and on Windows requires an installer + Npcap + administrator permissions. At an event that's 40 minutes of support before the first challenge.
- ACI IPs are dynamic: any printed guide with IPs becomes obsolete on the next redeploy.
  Same applies to a list of services distributed as PDF.

What's wanted: a command, without privileges, cross-platform, that in seconds answers **"what
is alive in what I can reach, and on what ports"**, calculated in real-time against the real network.

What is **not** wanted, and must be written down because it's the obvious temptation: that the
tool is a cheat sheet. If it says more than a legitimate scan would, it stops being a
reconnaissance tool and becomes a partial solution to the challenges.

## Design decision: scope from tunnel, names from resolver, results from network

The tool combines both proposed ideas, but with a strict hierarchy among them —
**they are not two equivalent paths**:

1. **Scope (which CIDRs to scan) is derived from the active WireGuard tunnel**, not from DNS and not from a
   per-team table. The tunnel already *is* the answer to "what can I reach": the gateway enforces it with
   `iptables` and the client enforces it with `AllowedIPs`.
2. **Host existence and its ports are always determined with a real TCP connection** to the
   host. Never with DNS, never with a table, never with cache.
3. **DNS is solely a names layer on top of results**: consulted *after*
   knowing what is alive, to decorate each IP with its FQDN if it has one. If DNS fails, the
   tool still works and shows IPs.

This hierarchy is the important decision of the document, and it's the same principle as "env vars stay in IP" from `internal-dns.md`: **DNS decorates, doesn't command.** A downed dnsmasq degrades the
output (empty FQDN column), it doesn't invalidate it.

### Why DNS cannot be the real source (idea 2 as primary path: discarded)

DNS enumeration is faster and more elegant, yet is discarded as the primary mechanism for three independent reasons:

- **Doesn't see hosts without records.** The caveat from `internal-dns.md` (team1, team2, and old DMZ don't
  have `dnsConfig` or, in manually recreated containers, updated records) is not
  transitory: any container recreated outside the normal flow stays without a name
  until the next `dns-sync`. A tool reporting "there's nothing in your network" because the
  team deployed before the migration is **actively incorrect**, and at an event that means
  a blocked team believing their challenge is down.
- **Requires guessing the namespace.** Resolving `<svc>.team<N>...` forces fixing a range
  of `N` (1..50? 1..255?) inside the package. That is exactly the "per-team hardcoding" that the
  requirement forbids, dressed up as a range.
- **Resolving is not reaching** (decision already made and tested in `internal-dns.md`). A list
  built from DNS mixes reachable with unreachable. Would need TCP verification anyway — that is,
  scanning doesn't save time, only sweep saves time.

What idea 2 does contribute, and is retained: DNS is the only cheap way to add names, and
**PTR** solves the mixed-case issue without enumerating anything (see below).

### Why not a backend in the lab

An inventory service (FastAPI in the DMZ, or reusing Prometheus from `vm-monitor`) would return
the exact answer in one call. Discarded, by the same criterion that discarded the shared
bot in `CLAUDE.md`:

- **Knows too much.** Real inventory includes teams that participants cannot reach.
  Filtering by team requires authenticating the participant — inventing per-team authn/authz for an
  afternoon event, with the `.conf` as the only existing credential.
- **Would lie about the only thing that matters.** Inventory says what exists; participants need
  to know what they *reach*, and that's decided by `iptables` on the gateway. A backend answering "10.60.7.5 exists"
  for a team that can't reach it creates the worst support bug possible.
- **`vm-monitor` is in `snet-mgmt`**, which by explicit decision is not published and not reachable
  from team tunnels. Exposing it would mean opening the staff plane to save 5 seconds of
  scanning.
- **It is new infrastructure** (one more container, one more deployment, one more surface
  that breaks on event day) for an issue solved 100% on the client with what already
  exists.

**Conclusion: zero new components in the lab.** The plan requires a `sysctl` tuning on the
gateway (see "What breaks first") and a change to the VPN client generator; nothing else.

### Why not a static inventory in the package

Discarded without discussion: violates the dynamic requirement, becomes obsolete on first redeploy, and
turns each `add-team` into an npm publication.

## How scope is determined, in real-time

Chain of sources, in order. First one that produces a result wins; all are deterministic and
none require privileges.

**S1 — `--cidr <a,b,c>` (explicit).** Escape hatch for staff and rare cases (route conflicts, admin tunnel). Always available, never automatic.

**S2 — `--conf <path to .conf>`.** Parses `AllowedIPs` from the file the participant already
downloaded. It's the **authoritative** source: literally what the gateway granted. Used if
the user passes it. **Not auto-discovered**: on Linux/macOS `.conf` files live in
`/etc/wireguard/` (root only) and on Windows the official client stores them encrypted with DPAPI in
`C:\Program Files\WireGuard\Data\Configurations\*.conf.dpapi` (requires administrator). Auto-
discovering them would require privileges on two of the three OSes, which is exactly what this design avoids.

**S3 — derivation from tunnel interface address (default path).**
Node's `os.networkInterfaces()` lists all interfaces with their IPv4, **without privileges and with
the same code on Windows, macOS, and Linux** (interface name changes — `wg0`, `utun4`, the
WireGuard adapter — but the address does not). It searches for an address within `10.200.0.0/16`,
which is the tunnel overlay, and from it derives the team:

```
10.200.<N>.2   ->  team N      (lo asigna create_wg_team_peer, lab-azure.sh:858)
10.200.0.2     ->  peer admin    (lab-azure.sh:920) -> no team; sweeps the superset of teams, see below
```

From `N` comes the scope: `10.60.<N>.0/24` + `10.50.0.0/24` + `10.51.0.0/24`.

This is **not hardcoding IPs**: there's not a single host address in the package. What is coded is
the *lab addressing plan* (three CIDR constants and the rule `10.200.N.2 → team N`),
which is an architectural constant documented in `CLAUDE.md`, changes only if the entire VNet is redesigned,
and lives in **a single file** in the package (`src/catalog.js`).

**S4 — OS routing table: evaluated and discarded.** It's the most "real" source (reflects what the
kernel will actually do), but requires parsing three distinct formats (`IP -4 route show dev wg0`,
`route print -4`, `netstat -rn -f inet`), each with locale and version variants. Three
fragile parsers to get information that S2 and S3 already provide exactly. Discarded by the
simplicity rule; if S3 proved unreliable on any OS, it's the first alternative to reconsider.

### Scope edge cases

| Case | Behavior |
|---|---|
| No interface in `10.200.0.0/16` | Actionable error: "I don't see an active Sabana Corp tunnel; bring up the VPN or pass `--conf`/`--cidr`". **Never** scan blindly. |
| Address `10.200.0.2` (admin) | No derivable team. WireGuard doesn't expose to the client what teams exist on the other side, so it scans the complete superset `10.60.0.0/16` (all possible `X`) + both DMZes, and warns that the scan takes longer than a single team's. The real AllowedIPs of the admin peer is already `10.0.0.0/8` (`lab-azure.sh:920`), this only decides what gets probed, not what can be reached. |
| Multiple interfaces in `10.200.0.0/16` | Error, listing candidates and asking for `--conf`/`--cidr`. Guessing here is worse than asking. |
| team > 254 | The peer scheme itself (`10.200.<N>.2`) has no more to give; it's a preexisting lab limit, not a tool limit. Documented, not solved here. |
| Participant's LAN uses `10.60.x` / `10.50.x` | Route conflict: can scan own LAN and see hosts outside the lab. Mitigation: output marks scope origin, and `--cidr` allows narrowing. See "risks". |

## How scanning works

**Real TCP connect scan, no raw sockets, no root.** Node's `net.Socket().connect()`. No SYN
scan, no OS detection, no version fingerprinting, no ICMP — not to simplify output,
but because all that requires elevated privileges or native libraries, which is precisely what
makes distribution unfeasible.

Here it's important to be precise about "half simulated": **results are not simulated at all**. What is constrained is the *method* (connect instead of SYN, fixed port catalog,
scope fixed by tunnel). The package **never prints a result it didn't measure**. A false "port
open" costs a team half an hour of challenge time; the rule is: zero synthetic results,
zero caching between runs, zero default values pretending to be measurements.

### Two phases

**Phase A — host discovery.** Probes a small subset of high-probability ports (`80, 22, 3306, 8080`) across all addresses in scope (3 × /24 = 762
useful addresses → ~3,048 attempts). As soon as a host responds on any port,
**remaining probes for that host are canceled** (less traffic, less conntrack, faster).

**Phase B — port details.** Only against live hosts from Phase A (typically 15-25), with
the complete port catalog of the lab (~18). About ~400 attempts: instant.

Expected typical cost: **5-8 s total**, dominated by timeout on empty addresses in Phase A. Without separated Phase A/B, it would be ~13,700 attempts and ~4× more pressure on the gateway.

### Definition of "alive"

**A host is alive if at least one port from the catalog responds** (connection accepted or explicitly rejected). No ping. Honest consequence to document in the package README: a host with no known open ports is indistinguishable from an empty IP — and for the participant's purpose that's fine, because a host that exposes nothing reachable is not an "available"
host.

If Phase 0 assumption 2 confirms ACI returns RST on closed ports, `ECONNREFUSED` is
treated as **evidence of a live host with that port closed**; if it turns out to discard,
timeout is indistinguishable from an empty IP and nothing is lost (the catalog covers the ports this lab
actually publishes).

### Port catalog

Union of what the repo templates actually publish — single array in `src/catalog.js`,
with a comment pointing to origin templates to prevent drift:

```
21  25  22  80  110  143  445  554  873  3000  3306  5432  8000  8080  8443  9090  9100  9418  443
```

(team: 3306, 80, 22, 80 — DMZ: 8080, and decoys; VMs in `snet-dmz-vm`: 80 and 443 for wiki and
CTFd). Expandable with `--ports`. Adding a port is a minor version bump of the package, and
**doesn't** require touching anything in the lab.

## How names are resolved — and the mixed case

**The lab resolver is queried directly, not the OS resolver.** Node allows
`new dns.Resolver()` + `setServers(['10.200.0.1'])`, which talks c-ares to that IP and **completely ignores
OS DNS configuration**.

This is a decision with more weight than it seems: it eliminates at a stroke the entire matrix of
split-DNS per OS documented in `internal-dns.md` ("WireGuard client and split-DNS
per OS"). Doesn't matter if Windows applied the NRPT rule, if `wg-quick` on Linux failed
due to missing `openresolv`, if the participant deleted the `DNS =` line from `.conf`, or if it's in
WSL2 with regenerated `/etc/resolv.conf`. The tool works the same in all those cases, because
it doesn't use the OS resolution stack. The only prerequisite is that `10.200.0.1/32` is in
`AllowedIPs` — which it already is since Phase 2 of the DNS plan.

**The mechanism is PTR (reverse), not forward.** For each live host,
`<inv>.in-addr.arpa` is queried against `10.200.0.1`. Reasons:

- **Solves the mixed case without enumerating anything.** A host with a record returns its canonical name
  (dnsmasq generates PTR from the first name in each line of `hostsdir` — decision already
  documented in `internal-dns.md`, "First name of each line is canonical"). A host without
  a record returns NXDOMAIN and displays as `-`. No need to guess names or team ranges.
- **It's O(live hosts)**, not O(possible names): ~20 queries, in parallel, milliseconds.
- **Never invents.** If the record is obsolete (old IP), PTR simply doesn't exist for the
  new IP → empty column, not a wrong name. It's the correct failure mode.

Fallback if PTR doesn't work (Phase 0 assumption 1 in red): forward resolution of known names catalog,
limited to **the participant's own team** (derived from tunnel, not from a guessed range)
+ fixed DMZ names, building an `IP → fqdn` map. It's more code and more fragile, and that's why PTR is verified before writing anything.

**Degradation**: if `10.200.0.1` doesn't respond in 1 s, the entire names layer is abandoned, a note is printed (`lab resolver: no response — showing IPs only`) and scanning continues
normally. DNS is not a prerequisite for `--scan`.

## Output format

Single command. `npx nmap-sabana-corp` and `npx nmap-sabana-corp --scan` do the same thing (`--scan`
is accepted for explicitness, it's what goes in the participant guide).

```
nmap-sabana-corp v1.0.0 -- TCP connect scan of accessible environment (no privileges)
scope  : 10.60.3.0/24, 10.50.0.0/24, 10.51.0.0/24   (origin: tunnel interface 10.200.3.2)
names  : 10.200.0.1 (lab resolver, active)

-- 10.60.3.0/24 -----------------------------------------------------------------
IP           FQDN                                        OPEN PORTS
10.60.3.4    database.team3.sabanacorp.internal          3306/tcp mysql
10.60.3.5    webapp.team3.sabanacorp.internal            80/tcp http
10.60.3.6    linux-server.team3.sabanacorp.internal      22/tcp ssh
10.60.3.7    -                                           80/tcp http

-- 10.50.0.0/24 -----------------------------------------------------------------
10.50.0.4    filesrv.dmz.sabanacorp.internal             8080/tcp http-alt
10.50.0.9    printer-01.dmz.sabanacorp.internal          80/tcp http, 9100/tcp jetdirect
...

-- 10.51.0.0/24 -----------------------------------------------------------------
10.51.0.4    wiki.dmz.sabanacorp.internal                80/tcp http
10.51.0.5    ctfd.dmz.sabanacorp.internal                80/tcp http

21 live hosts - 27 open ports - 762 addresses probed in 6.2 s
3 hosts without FQDN (no DNS record; not a failure -- see README)
```

Fields, and **nothing else**: IP, canonical FQDN (or `-`), list of open ports with service label.

### The rule governing what is shown

**The tool never says anything that the port number alone doesn't say.**

- Service label (`http`, `ssh`, `mysql`, `http-alt`) is derived **exclusively from port
  number**, with a generic IANA table. Never from host role, never from container,
  never from the template that generated it. `80` is `http` on both the challenge webapp and a decoy.
- FQDN is shown **verbatim, exactly as the resolver returns it**. That
  `xss-bot.team3.sabanacorp.internal` hints at something is not a tool decision: it's
  a consequence of the flat zone already decided in `internal-dns.md`, where the name is already
  discoverable with `dig`. Reproducing what DNS already publishes adds no filtering; inventing
  annotations does.

### What is explicitly NOT shown

| Not shown | Why |
|---|---|
| Banners, HTTP titles, headers, TLS certificates | Can reveal versions with known CVEs, or challenge text → hint |
| Service version or product (`-sV`) | Same, and would require real fingerprinting |
| OS detection | Requires privileges and adds nothing to the game |
| Closed/filtered ports one by one | Noise; plus turns output into a map of the port catalog |
| Any annotation of role, challenge, difficulty, or vulnerability | It's the red line of the requirement |
| Subnets of other teams | Outside tunnel scope: only produces timeouts and support tickets |
| `snet-mgmt` (`10.99.0.0/24`) | Not published and not reachable, by prior decision |
| Routes, endpoints, directories | Not a web scanner and must not become one |

`--json` outputs exactly the same fields in JSON (for scripting and for staff reuse); no "extra" hidden fields in JSON — same information, different format.

## Package architecture

### Runtime and dependencies

**Node.js ≥ 18, ESM, zero runtime dependencies.** Everything the package does is in the standard library: `net` (connect scan), `dns.Resolver` (names against `10.200.0.1`), `os`
(`networkInterfaces`), `node:test` (tests). Zero dependencies means: instant installation,
zero supply-chain surface, and a single copiable file as plan B (see "Distribution").

Discarded:
- **Python** (`python -m sabana_scan`): no equivalent to `npx` that works as well on
  Windows, and version/venv fragmentation on student laptops is worse than Node's.
- **Go / compiled binary** (or Node with `pkg`): would give a runtime-free executable, but requires
  compiling and distributing 3 binaries, signing/notarizing on macOS, and — the killer point — **an
  unsigned binary opening thousands of TCP connections is a sure candidate for Windows Defender or
  the university's EDR to quarantine on event day**. A readable `.js` has less chance of triggering
  heuristics and, if it does, the participant can read it.
- **Wrapping real nmap**: reintroduces nmap/Npcap installation and administrator privileges,
  which is the original issue.

### Structure

```
tools/nmap-sabana-corp/
  package.json          bin: { "nmap-sabana-corp": "bin/cli.js" }, type: module, files: [...]
  bin/cli.js            flag parsing, orchestration, output codes
  src/scope.js          S1/S2/S3: --cidr, --conf, derivation from os.networkInterfaces()
  src/scan.js           2-phase connect scan, concurrency pool, per-host cancellation
  src/names.js          dns.Resolver against 10.200.0.1, PTR, degradation
  src/render.js         text table and --json
  src/catalog.js        ONLY file with lab knowledge: CIDRs, rule 10.200.N.2, ports
  test/*.test.js        node --test, no framework
  README.md             participant guide (installation, usage, "what does each column mean")
```

`src/catalog.js` is the file to review if the addressing plan or services ever change. Isolated on purpose: the rest of the package knows nothing about Sabana Corp.

### Where the code lives

**Inside this repo, at `tools/nmap-sabana-corp/`.** Not in a separate repo.

Reason: the only non-generic package content (CIDRs, naming convention, port catalog) is derived from `yamls/templates/*.yaml.tpl` and `lab-azure.sh`, which live here. A separate repo
guarantees silent drift: someone adds a decoy with a new port and the scanner stops seeing it, with nothing flagging it. Living together, the change appears in the same diff and `docs/` is already
where this project documents that kind of coupling.

`../sabana-corp-network` (where challenge images live) was evaluated: discarded because the
package depends not on images but on topology, which is in this repo.

### Publication and versioning

- **Semver.** `patch` = fixes; `minor` = changes to `catalog.js` that alter results
  (new port, new CIDR); `major` = change to `--json` format or flags.
- **GitHub Actions with tag `nmap-v*`**, same pattern as `../sabana-corp-CTFd/.github/workflows/
  deploy.yml`: `npm ci && npm test && npm publish --provenance`, with `NPM_TOKEN` in secrets.
  Manual publishing from the operator's laptop is explicitly discarded (unrepeatable, no trace).
- **Reserve the name on npm now**, with an empty `0.0.1` version, before the event. Typosquatting a
  package that people will run with `npx` on a lab network is a real risk and
  mitigation takes five minutes.
- The package is **public**. Contains no secrets: CIDRs are RFC1918 and mean nothing outside
  the tunnel, and the port catalog is the same anyone gets by scanning. Verify
  anyway that nothing from `yamls/.env.secrets` enters via the `files` field in `package.json`.

### Distribution to participants (the point that can ruin the event)

**`npx` needs internet to npm registry at the exact event moment.** The lab has no
internet output, and access goes through a captive portal. Although the WireGuard tunnel doesn't
capture the default route (`AllowedIPs` are only lab CIDRs, so normal participant navigation stays on their usual route), relying on that on event day is
betting the first challenge on the auditorium's network.

Three layers, in order:

1. **Pre-flight**: the participant guide (the `README.md` already generated with `.conf`)
   asks for `npm i -g nmap-sabana-corp` **before** arriving, and `nmap-sabana-corp --version` as
   verification.
2. **Local copy with `.conf`**: `generate-wg-client.sh` leaves in
   `yamls/generated/wg-clients/` a copy of the package bundled into a single file
   (`nmap-sabana-corp.mjs`, executable with `node nmap-sabana-corp.mjs`). It's viable *precisely*
   because the package has no dependencies. The participant already receives that directory: the
   tool travels with the tunnel it will scan.
3. **No network and no file**: there is no plan C, and there doesn't need to be — the `.conf` and tool are
   delivered together.

## What breaks first: conntrack on the gateway

This is the scaling risk of the plan, and it's not about the package but about the lab.

Each Phase A connection attempt to an **empty but allowed** address (within the
team's own `/24` or the DMZ) is a SYN that the gateway *forwards* and no one answers. That
flow sits in the conntrack table in `SYN_SENT` state, and the timer that frees it is
`nf_conntrack_tcp_timeout_syn_sent` — **120 s by default**, completely independent of
the socket timeout the tool uses. Lowering the client timeout doesn't help at all here.

Napkin math with 4 ports in Phase A:

| Scenario | conntrack entries in ~2 min |
|---|---|
| 1 team scans | ~2,500 |
| 20 teams scanning at event start (real case: all at once) | ~50,000 |
| 20 teams scanning twice (second try because "nothing came up") | ~100,000 |

Default `nf_conntrack_max` on a small Ubuntu VM is in the tens of thousands. If it fills, the gateway **drops new traffic from all peers**, not just the scanner: the entire VPN goes down for everyone, with a symptom ("everything is slow / disconnected") that doesn't point to the cause. It's the most expensive failure this tool can produce.

Note: traffic to **other teams** (blocked by `iptables` in `FORWARD`) doesn't contribute — a
packet dropped in `FORWARD` never confirms its conntrack entry. The issue is empty addresses in subnets the participant **does** have permission to.

Mitigations, in order of importance:

1. **`sysctl` on gateway** (the only thing this plan asks of the lab, and it's one line):
   `net.netfilter.nf_conntrack_max=262144` and
   `net.netfilter.nf_conntrack_tcp_timeout_syn_sent=20`. Add to
   `yamls/wg-gateway/cloud-init.yaml` (for future gateways) and apply via `run-command` on the
   live VM (the "live-apply, don't recreate" pattern already used in this repo).
2. **Phase A with few ports** (4, not 18) and per-host cancellation: the difference between 2,500 and
   11,000 entries per team.
3. **Moderate default concurrency** (128 simultaneous sockets, not 1024). It's slower on paper and nearly the same in practice, because
   the bottleneck is timeout, not parallelism. Adjustable with `--concurrency` for staff.
4. **Deferred decision with measurable trigger**: if the load test (Phase 0, assumption 3) shows
   that even with `sysctl` N teams can't sustain simultaneous scanning, the default mode reverses —
   becomes "DNS first" (resolve own team + DMZ names, ~20 targets, no sweep) and full sweep goes behind `--deep`. Would be a worse tool (brings back the blind spot of hosts without FQDN) but doesn't crash the gateway. **Don't take this decision without measurement.**

A `node_exporter` on the gateway would give `node_nf_conntrack_entries` and close the loop with an
alert. It's outside this plan's scope (today `node_exporter` only runs on `vm-monitor`); noted as input to `docs/plans/observability-monitoring.md`.

## Changes needed in the lab

Surprisingly few. The tool works against the lab **just as it is today**.

| Change | Mandatory | Where |
|---|---|---|
| Conntrack `sysctl` on gateway | **Yes** (see above) | `yamls/wg-gateway/cloud-init.yaml` + `run-command` on live VM |
| Package copy with `.conf` + section in participant README | Yes (distribution) | `yamls/generate-wg-client.sh`, `yamls/templates/wg-client-readme.md.tpl` |
| `10.200.0.1/32` in `AllowedIPs` | Already done | `create_wg_peer` (`lab-azure.sh:843`) |
| dnsmasq answering PTR | Already done, **not verified from tunnel** | Phase 0 |
| All hosts have FQDN | **No** — and must not become a requirement | — |
| New backend / service | **No** | — |

The most important row is the second-to-last: this design is built so the mixed case is
permanent. If someone later decides to recreate team1/team2 to give them `dnsConfig`, the
tool improves (more FQDN columns filled) but doesn't change. **Never the other way**: don't turn
"all hosts have DNS" into a tool requirement, for the same reason container env
vars stay in IP.

## Implementation phases

**Phase 0 — Verify assumptions (half day, no production code).**
1. PTR from team tunnel: `dig -x 10.60.1.4 @10.200.0.1` with `team1.conf` up.
2. Closed port on ACI container: `nc -vz <IP-webapp> 22` → RST or timeout?
3. **Load**: synthetic sweep (20-line script, not the package) simulating 5 and 20 teams
   simultaneously, measuring `conntrack -C` on gateway before/during/after, with and without `sysctl`.
   This one can change the design.
4. Node on laptops: ask in the call. Determines weight of distribution layer 2.

**Phase 1 — Package core, not published.** `scope.js` + `scan.js` + `render.js` + catalog.
Verifiable against real lab from operator's laptop with `admin.conf` and `--cidr`. No npm,
no lab changes.

**Phase 2 — Names layer.** `names.js` (PTR against `10.200.0.1`), degradation with dnsmasq
intentionally stopped. Verifiable with `team1.conf` (hosts **without** FQDN, per caveat) and a
team deployed after migration (hosts **with** FQDN) — mixed case tested for real,
not in theory.

**Phase 3 — Lab hardening.** Conntrack `sysctl` in cloud-init + live-apply, repeat
Phase 0 load test with the real package.

**Phase 4 — Publication and distribution.** `package.json`, GitHub Actions workflow, name reservation, single-file bundle in `generate-wg-client.sh`, section in participant README.

**Phase 5 — Documentation.** `CLAUDE.md` (section "design decision" with scope/network/names hierarchy and "no hints" rule), `yamls/README.md`, cross-note in
`internal-dns.md` (PTR gains a real consumer) and `observability-monitoring.md`
(gateway conntrack). Last on purpose: document what was measured.

**Phase 6 — Explicitly out of scope for event.** Version/banner detection, web scanning, "hint" mode. Written here so the decision not to do it is deliberate.

## Test plan

```bash
# scope (no tunnel, unit)
node --test tools/nmap-sabana-corp/test/        # scope: 10.200.7.2 -> 10.60.7.0/24 + DMZs
                                                # scope: no 10.200/16 interface -> actionable error
                                                # scope: AllowedIPs parsing with/without spaces

# against real lab, team1.conf up
node bin/cli.js --scan                          # team1 hosts + both DMZ, FQDN empty where it should
node bin/cli.js --scan --json | jq '.hosts|length'

# real mixed case
./lab-azure.sh add-team 9                       # new team -> YES has dnsConfig/record
# bring up team9.conf and verify: FQDN present on all 4, absent on old DMZ

# resolving ≠ reaching (test that documents security model)
# with team1.conf: sweep must NOT list any host from 10.60.2.0/24
node bin/cli.js --scan --cidr 10.60.2.0/24      # 0 live hosts, gateway raises its DROP counter

# DNS degradation
az vm run-command invoke ... --scripts "systemctl stop dnsmasq"
node bin/cli.js --scan                          # same hosts and ports, FQDN column all '-'
az vm run-command invoke ... --scripts "systemctl start dnsmasq"

# load (test that can change design)
# 5 and 20 simultaneous sweeps; on gateway, before/during/after:
az vm run-command invoke ... --scripts "conntrack -C; sysctl net.netfilter.nf_conntrack_max"
# criterion: usage < 50% of max, and VPN of a peer that's NOT scanning still responds

# cross-platform (non-negotiable: where the risk lives)
# Windows 11 (official client), macOS (official app), Linux (wg-quick), WSL2
```

## Risks and mitigation

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| 1 | Conntrack exhaustion on gateway with N teams scanning at once | **VPN down for everyone**, not just scanner | `sysctl` (`nf_conntrack_max`, `syn_sent=20`), Phase A with 4 ports, concurrency 128, load test in Phase 0 |
| 2 | Participant has no Node installed | Cannot use tool | Pre-flight in call; measure in Phase 0; `.conf` and single file travel together |
| 3 | `npx` fails due to no internet in auditorium | Failure right at event start | Prior `npm i -g` + single-file copy with `.conf` |
| 4 | Antivirus/EDR quarantines tool ("port scanner") | Per-team block, hard to diagnose | Readable `.js` vs unsigned binary; moderate concurrency; note in README |
| 5 | Participant's LAN overlaps `10.50/10.60` | Scans own network; confusing or embarrassing results | Scope origin printed in header; `--cidr`; note in README |
| 6 | `os.networkInterfaces()` doesn't show WireGuard adapter on some OS/version | Auto-detection fails | Fallbacks `--conf` and `--cidr`; test on 4 environments in Phase 4 |
| 7 | dnsmasq doesn't answer PTR for `hostsdir` entries | Names layer fails | Phase 0 tests before writing `names.js`; forward fallback limited to own team |
| 8 | Port catalog drifts from templates | Live hosts invisible to tool | Package in same repo; cross-comment in `catalog.js`; `yamls/` README mentions it |
| 9 | Someone adds banners/version "to look more like nmap" | Challenge hints leak | Rule written ("nothing the port alone doesn't say") in `CLAUDE.md` and `render.js` header |
| 10 | Package becomes challenge dependency (a hint says "run the scanner") | Tool failure crashes a challenge | Tool is for convenience, never data plane — same as DNS |
| 11 | Name typosquatting on npm | Arbitrary code on participant laptops | Reserve name before event; publish with provenance; README lists exact URL |
| 12 | Name `nmap-*` on public package suggests Nmap affiliation | Minor, but real | Explicit note in README ("not nmap, doesn't use its code"); alternate bin alias available |
| 13 | Participant thinks "0 hosts" means "lab is down" | Support tickets | Explicit message when 0 hosts: first verify tunnel (`--conf`), then alert staff |

## Acceptance criteria

1. `npx nmap-sabana-corp --scan` with `team<N>.conf` up lists the 4 team hosts + both DMZ hosts, in
   **less than 10 s**, without administrator privileges, on Windows, macOS, and Linux.
2. Header prints scope and its origin; scope matches exactly the `AllowedIPs`
   of that team's `.conf`.
3. No hosts from other teams appear in output (even if their names resolve).
4. DNS-registered hosts show FQDN; unregistered hosts show `-`; **both cases appear in
   the same run** (mixed case tested for real).
5. With dnsmasq stopped: same hosts and ports, FQDN column all empty, no errors.
6. Output contains no banners, versions, titles, or role/challenge annotations — checked
   against the table "What is explicitly NOT shown".
7. `--json` contains the same fields as the table, no more.
8. 20 simultaneous sweeps keep gateway conntrack use below 50% and don't
   degrade VPN of a peer not scanning.
9. Zero dependencies in `package.json`; `npm pack` produces a tarball without secrets.
10. Single-file copy delivered with `.conf` produces identical output to published package.
11. `CLAUDE.md` documents the hierarchy (scope = tunnel, facts = TCP, names = decoration) and
    the no-hints rule.

## Open / not decided

- **Real service detection (banners/`-sV`)**: discarded for the event (leaks hints). Only
  reconsiderable if someone defines, per service, what is publishable — and that's a CTF scenario
  decision, not architecture.
- **Mark which hosts are decoys**: useful for support and **lethal** for the game. No.
- **`--watch` mode** (continuous re-scan): tempting to see a challenge restart, but multiplies
  conntrack pressure by K (risk 1). Out until load measurement is done.
- **Telemetry** (tool reports to staff who scanned and when): interesting as
  progress signal, but requires a backend — exactly what this plan discards. Fits better as
  dnsmasq `log-queries` in `docs/plans/observability-monitoring.md`, already noted there.
- **UDP**: lab publishes no reachable UDP service (only WireGuard 51820, not a target). No use case; plus UDP scanning without privileges is unreliable.
- **IPv6**: VNet is IPv4 only. Doesn't apply.
- **Reuse package for staff `status`**: `--json` would allow it, but `lab-azure.sh
  status` already reads Azure control plane, a better source (sees crashed containers, scanner doesn't). Don't unify.
- **Package name**: `nmap-sabana-corp` is the explicit request of the project owner and is
  respected. Alternatives if the brand nuance bothers: `sabanacorp-recon`, `sabana-scan` (can be
  published as bin alias without changing the package).

# nmap-sabana-corp

> **`0.1.0-draft`: functional build (36/36 unit tests), but NOT yet validated against the real lab**
> -- missing the three Phase 0 assumptions from the plan (PTR from a real tunnel, closed port
> behavior in a live ACI container, conntrack pressure on the gateway with N teams scanning).
> Do not use yet as the official event tool; version `1.0.0` will replace this once those
> assumptions are verified. Details: `docs/plans/nmap-sabana-corp.md`.

Network discovery without privileges for the Sabana Corp CTF. A single command that answers "what
is alive in my accessible range, and on which ports" -- computed in real time against the actual
network, never against a fixed list.

**It is not nmap.** It does not use its code, does not reimplement its engine. It does only one
thing that nmap also does (TCP connect scan) with the name chosen to make clear what it is to a
participant who probably does not have nmap installed.

## Installation

```bash
npm install -g nmap-sabana-corp
nmap-sabana-corp --version   # pre-flight check, do this BEFORE the event
```

The lab has no internet access (captive portal + VPN). If you couldn't install it beforehand,
look for `nmap-sabana-corp.mjs` in the same folder as your `<team>.conf` -- it travels along
with the tunnel, without needing network or `npm`:

```bash
node nmap-sabana-corp.mjs --scan
```

## Usage

With your team's WireGuard tunnel up:

```bash
nmap-sabana-corp
nmap-sabana-corp --scan       # exactly the same; --scan is explicit, does nothing different
nmap-sabana-corp --json       # same fields, in JSON
```

You don't need to specify anything else: scope is derived automatically from your tunnel
interface (looks for an address within `10.200.0.0/16`). Other options:

| Flag | What for |
|---|---|
| `--cidr <a,b,c>` | Explicit scope. Escape hatch for staff or for routing conflicts. |
| `--conf <path>` | Derives scope by reading `AllowedIPs` directly from a WireGuard `.conf` -- the most authoritative source there is. |
| `--ports <a,b,c>` | Add extra ports to the lab catalog. |
| `--concurrency <n>` | Simultaneous sockets (default 128). Lower this if your network is unstable. |
| `--json` | Output in JSON instead of text table. |
| `--version` / `--help` | The usual. |

## How it works (summary)

1. **Scope**: from your WireGuard tunnel (or from `--conf`/`--cidr` if you pass them). Never guessed.
2. **Facts**: every host and every port is measured with a real TCP connection (`net.Socket().connect()`,
   no privileges, no raw sockets). A host is considered alive if at least one port from the catalog
   responds -- accepted or explicitly rejected. Zero simulated results, zero cache.
3. **Names**: after learning what is alive, the lab's DNS resolver
   (`10.200.0.1`, never your system's) is asked for the PTR name of each live IP. If the resolver
   doesn't respond in 1 second, the tool keeps working and shows only IPs.

Full details of the three decisions (why in that order, why TCP and not DNS, why PTR and
not forward) in `docs/plans/nmap-sabana-corp.md` in the `sabana-corp-cloud` repo.

## What each column means

```
IP           FQDN                                        OPEN PORTS
10.60.3.4    database.team3.sabanacorp.internal          3306/tcp mysql
10.60.3.7    -                                            80/tcp http
```

- **IP**: real address, measured in this run.
- **FQDN**: canonical name returned by the lab's resolver, or `-` if it has no DNS record.
  **A `-` is not a tool failure nor a challenge failure** -- there are hosts in this lab that
  never had DNS records (they were deployed before that layer existed) and will keep it that way.
  A missing name doesn't mean the host is broken, or that you can't reach it: the next column
  (ports) already confirms it.
- **OPEN PORTS**: port, protocol, and a generic service label (IANA table,
  derived exclusively from port number -- `80` is `http` regardless of the container behind it).

## What this tool never shows, on purpose

| Never shown | Why |
|---|---|
| Banners, HTTP titles, headers, TLS certificates | Can leak a version with a known CVE, or challenge text |
| Service version or product (`-sV`) | Same, and would require real fingerprinting |
| OS detection | Requires privileges and adds nothing to the game |
| Closed/filtered ports one by one | Noise; would turn output into a map of the internal catalog |
| Any annotation of role, challenge, difficulty, or vulnerability | It is the red line of this tool |
| Other teams' subnets | Outside your real reach; would only produce timeouts |
| `snet-mgmt` (staff infrastructure) | Not published or reachable, by design |
| Routes, endpoints, directories | This is not a web scanner |

If this tool ever tells you something that the port number alone wouldn't tell you, it's a
bug -- report it to staff.

## "I see nothing" / 0 hosts alive

Before thinking the lab is down:

1. Verify that your WireGuard tunnel is really up (`wg show`, or the status in the official app).
2. Run `nmap-sabana-corp --conf <your-team>.conf` -- if with `--conf` you still see nothing, then
   tell staff.

A host with no catalog ports open is indistinguishable from an empty IP -- and
for reconnaissance purposes that's fine: if it exposes nothing reachable, it's not an
"available" host for the challenge.

## Resolving ≠ reaching

You will be able to see names from other teams if you ask for them manually (the lab's DNS zone
is flat, no `split-horizon`): network reconnaissance is part of the game. A name resolving
**does not** mean you can reach it -- the real access control is on the VPN gateway, not in
DNS. You will see `webapp.team7.sabanacorp.internal`, but connecting to another team's network
is exactly what this CTF challenges you to achieve, not something this tool gives you for free.

## Zero dependencies, on purpose

This package depends on nothing outside Node's standard library (`net`, `dns`, `os`). That
means instant installation and, more importantly, you can read the complete source code
(`src/`) in a while if you want to confirm exactly what it does before running it on your laptop.

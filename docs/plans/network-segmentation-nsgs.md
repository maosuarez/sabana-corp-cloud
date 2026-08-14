# Plan: NSG segmentation rules between subnets

## Status

**Step 1 of the rollout order (team↔team isolation) implemented and validated end-to-end against
the real lab (2026-08-14).** Found live: a participant on team1's VPN tunnel reached
`team1-linux-server` (10.60.1.7) as intended, then from that box SSHed straight into
`team2-linux-server` (10.60.2.7) — full lateral movement across teams, because nothing at the
Azure network layer enforced the matrix below once traffic was already inside the VNet (the
gateway's `iptables` in `docs/plans/wireguard-vpn-gateway.md` only controls what a *VPN client*
can reach directly, not what an already-reachable VM/container can reach from there).

Fix: `lab-azure.sh` now creates one NSG per team (`nsg-team<N>`, `create_team_nsg`), attached to
`snet-team<N>`, allowing only that team's own `/24` and denying the rest of `TEAM_SUPERNET_CIDR`
(`10.60.0.0/16`) — both inbound and outbound. Wired into `add_team_subnet` so every future
`add-team`/`add-team-range` gets it automatically; `./lab-azure.sh secure-teams` retrofits teams
created before this fix (used once for team1/2/3, the three live at the time). Verified live via
`az container exec` and direct SSH: team1↔team2, team1↔team3 and team2↔team3 all now drop (silent
NSG deny, TCP connect times out — not an immediate refuse), while intra-team traffic (webapp↔db)
and team→DMZ (the actual challenge path) are untouched.

**Steps 2 (DMZ → teams denied) and 3 (everything → `snet-mgmt` denied) implemented and validated
end-to-end against the real lab (2026-08-14), same session as step 1.** `create_dmz_shared_nsg` /
`create_dmz_vm_nsg` (`nsg-dmz-shared`, `nsg-dmz-vm`) deny outbound from either DMZ subnet to
`TEAM_SUPERNET_CIDR` and to `MGMT_CIDR` — DMZ-shared↔DMZ-vm traffic is untouched since neither
prefix is denied, and inbound is left at Azure's default (fully open) since teams and mgmt both
need to reach DMZ. `create_mgmt_nsg` (`nsg-mgmt`) denies inbound to `snet-mgmt` from
`TEAM_SUPERNET_CIDR` and from both DMZ prefixes, in a single rule set on mgmt's own NSG rather
than duplicating an outbound-deny on every team/DMZ NSG — a subnet added later is protected
automatically. Outbound from `snet-mgmt` is untouched (`mgmt → everything` stays allowed).

Wired into `create_vnet()` (dmz-shared/dmz-vm/mgmt subnets get their NSG at creation time, same as
teams get theirs in `add_team_subnet`); `./lab-azure.sh secure-network` retrofits every subnet
that already existed (teams + DMZ + mgmt in one idempotent pass — supersedes `secure-teams` for a
full retrofit, which still works standalone for teams only).

Verified live (`az container exec` with `nc`, `az vm run-command invoke` for the VMs):
`dmz-filesrv → team1-linux-server:22` and `dmz-filesrv → vm-monitor:3000` both drop; `vm-wiki
(dmz-vm) → team1:22` and `vm-wiki → vm-monitor:3000` both drop; `dmz-filesrv ↔ vm-wiki` (DMZ↔DMZ)
stays open; `team1 → vm-monitor:3000` drops; `team1 → DMZ filesrv:8080` and `vm-monitor → team1
webapp / dmz-filesrv / vm-wiki` (monitoring scrapes) all stay open. The full matrix in "Proposed
rule matrix" below is now implemented exactly as specified.

The DNS exception noted in that section never applied: `10.10.0.4` (the gateway/dnsmasq) is
outside `TEAM_SUPERNET_CIDR` and both DMZ prefixes, so none of these deny rules ever touch it.

See `CLAUDE.md` ("Target network architecture") for the broader picture: before this work, not a
single NSG existed on the lab's subnets other than `nsg-wg-gateway` (VPN inbound only) — team,
DMZ and mgmt subnets had complete default Azure intra-VNet routing between them.

## Problem

Azure routes by default between all subnets of the same VNet without restriction. Today (`vnet-ctf-lab`, `10.0.0.0/8`) that means:

- `snet-team1` can reach `snet-team2`, `snet-team3`, etc. — breaks the team isolation that the CTF requires (one team could directly attack another's infrastructure instead of their own).
- Any subnet can reach `snet-mgmt` — if CTFd, Provisioner, Monitor, or the admin jumpbox ever live there, a participant could reach them directly without any control.
- A compromised container in `snet-dmz-shared` or `snet-dmz-vm` (they're CTF targets — filesrv, wiki, parking, decoys, all meant to be exploited) could theoretically initiate connections to `snet-teamX` or `snet-mgmt` and serve as a pivot beyond what the challenge design intended.

This was already identified as a gap in the xss-bot shared design decision (`CLAUDE.md`, "xss-bot is N instances") and in `yamls/README.md` ("Access from the internal network") — this doc is where that pending item is closed with a concrete proposal.

## Threat model (summary)

- **Teams are mutually untrusted** — each should only be able to attack their own infrastructure and shared DMZ services, never another team's infrastructure.
- **The DMZ (shared and DMZ-VM) is intentional attack surface** — teams are expected to exploit it. It shouldn't, in turn, be able to initiate connections to teams (prevents compromising a decoy/wiki from becoming a pivot to team1 instead of a dead end as intended).
- **`snet-mgmt` is the staff plane** — CTFd, Provisioner, Monitor, and any admin tooling. No team or DMZ service should reach it. Valid traffic goes the other direction (staff/monitoring initiating to teams and DMZ for scraping, health checks, etc.).
- **`snet-wg-gateway` is the entry point** — receives VPN client traffic from the internet and routes inward. **Resolved in `docs/plans/wireguard-vpn-gateway.md`** (2026-08-08): access control there isn't implemented as an NSG (see note below the matrix).

## Proposed rule matrix

Source (rows) → Destination (columns). `✓` allowed, `✗` denied, `—` not applicable / out of scope for this doc.

| Origen \ Destino  | snet-teamX (mismo) | snet-teamX (otro) | snet-dmz-shared | snet-dmz-vm | snet-mgmt | snet-wg-gateway |
|-------------------|:---:|:---:|:---:|:---:|:---:|:---:|
| **snet-teamX**    | ✓   | ✗   | ✓   | ✓   | ✗   | —   |
| **snet-dmz-shared** | ✗ | ✗   | ✓   | ✓   | ✗   | —   |
| **snet-dmz-vm**   | ✗   | ✗   | ✓   | ✓   | ✗   | —   |
| **snet-mgmt**     | ✓   | ✓   | ✓   | ✓   | ✓   | —   |
| **snet-wg-gateway** | — | —   | —   | —   | —   | —   |

Notes on the matrix:

- **snet-teamX → snet-teamX (same)**: intra-team traffic, always allowed (how the 4 containers of the same team communicate today).
- **snet-teamX → another snet-teamY**: denied — team isolation.
- **snet-teamX → DMZ (shared/vm)**: allowed — it's the real challenge objective (pivot from your own building to filesrv/wiki/parking/decoys).
- **DMZ → snet-teamX**: denied in both directions — compromising a DMZ service shouldn't grant access to any team's network.
- **DMZ-shared ↔ DMZ-vm**: allowed to each other (both are "the DMZ", only separated by the technical limitation of ACI vs. VM — see `docs/plans/wiki-on-vm.md`). E.g.: if someday a `snet-dmz-shared` container needs to talk to the wiki in `snet-dmz-vm`, there's no reason to block it.
- **Nobody (teams or DMZ) → snet-mgmt**: denied — isolated staff plane.
- **snet-mgmt → everything**: allowed — monitoring/admin needs broad visibility. If this is too permissive when Monitor/Provisioner really deploy, revisit (could narrow to specific scraping ports instead of "everything").
- **snet-wg-gateway**: row/column deliberately blank — VPN client access control isn't modeled in this matrix. See note below.

## Implementation notes (for when this is decided to be applied)

- One NSG per subnet (Azure allows attaching an NSG to a subnet directly, without depending on individual NICs) — simpler to reason about than a shared NSG with rules by source IP.
- NSGs on ACI-delegated subnets (`snet-dmz-shared`) are compatible — Azure allows attaching NSGs to subnets delegated to `Microsoft.ContainerInstance`. Shouldn't be any surprises there, but good to test against a single container before applying it to the 14 already running, to avoid breaking `deploy_dmz` midway through an event.
- "Deny team→team" rules need an explicit **deny** entry for each active team range (or a rule that only allows that team's own `10.60.<N>.0/24` block and denies the rest of `10.60.0.0/16`) — since `add-team <N>` creates subnets on-demand, each `snet-teamX`'s NSG should be generated/updated in the same step that creates the subnet (`lab-azure.sh: add_team_subnet`), not manually.
- Recommended: apply this first against a single test team (team1, already deployed) and confirm with `az container exec` + cross-subnet `curl`/`nc` that rules behave as expected, before generalizing to `add-team` for future teams.
- Suggested rollout order: (1) block team↔team, (2) block DMZ→teams, (3) block everything→mgmt — from lower to higher probability of breaking something already working, so you can quickly isolate which rule caused a problem if something breaks.

## Note: Internal DNS (`docs/plans/internal-dns.md`, implemented)

If this plan's NSGs are ever applied, **`snet-team*` and `snet-dmz-*` must be able to reach `snet-wg-gateway` on UDP/TCP 53** — that's where dnsmasq lives (`10.10.0.4`). The matrix above leaves that column blank ("out of scope"), which is correct today because no NSGs are created, but would become silent DNS cutoff for all containers once someone materializes this matrix. Same warning for a future `snet-wg-gateway` NSG: if its policy ever moves from today (no subnet NSG, just the `nsg-wg-gateway` that already exists) to something like `DenyVnetInBound`, an `allow-dns-inbound` rule (53 from `VirtualNetwork`) must be added first or the gateway stops resolving names for the whole VNet unnoticed until someone asks why `curl http://webapp.team3...` stopped working.

## Open / not decided

- ~~Policy for `snet-wg-gateway`~~ — **resolved, not via NSG.** VPN client access control is implemented on the gateway itself (`vm-wg-gateway`): `iptables FORWARD` rules by WireGuard tunnel IP, with `DROP` policy by default — not in a subnet NSG. Reason: this matrix is per-subnet grain, and VPN control needs to be per-peer (two teams share the `snet-team<N>` "class" but need mutually exclusive access, which a subnet NSG can't express without completely duplicating `add-team`'s lifecycle). See `docs/plans/wireguard-vpn-gateway.md` for the full design. The rest of this matrix (team↔team, DMZ→teams, everything→mgmt) is now implemented (see "Status" above) and applies to traffic *within* the VNet that doesn't go through the gateway, same as it always did.
- If Monitor/Provisioner end up living in `snet-mgmt` needing to expose a port to teams (e.g., Provisioner answering a webhook), the rule "`snet-mgmt → everything` yes, nobody → `snet-mgmt`" would need a point exception — don't block that case preventively without knowing it applies.

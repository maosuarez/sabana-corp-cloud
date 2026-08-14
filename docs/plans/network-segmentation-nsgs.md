# Plan: NSG segmentation rules between subnets

## Status

Not implemented. Design/documentation only for now — the explicit request was "let's document that", not apply it yet. See `CLAUDE.md` ("Target network architecture") for current state (complete freedom, not a single NSG created on the lab's subnets; the only NSG today, `nsg-jumpbox`, is ad hoc for SSH from a test jumpbox and doesn't express any real segmentation policy).

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

- ~~Policy for `snet-wg-gateway`~~ — **resolved, not via NSG.** VPN client access control is implemented on the gateway itself (`vm-wg-gateway`): `iptables FORWARD` rules by WireGuard tunnel IP, with `DROP` policy by default — not in a subnet NSG. Reason: this matrix is per-subnet grain, and VPN control needs to be per-peer (two teams share the `snet-team<N>` "class" but need mutually exclusive access, which a subnet NSG can't express without completely duplicating `add-team`'s lifecycle). See `docs/plans/wireguard-vpn-gateway.md` for the full design. The rest of this matrix (team↔team, DMZ→teams, everything→mgmt) remains unimplemented and still applies as-is to traffic *within* the VNet that doesn't go through the gateway.
- If Monitor/Provisioner end up living in `snet-mgmt` needing to expose a port to teams (e.g., Provisioner answering a webhook), the rule "`snet-mgmt → everything` yes, nobody → `snet-mgmt`" would need a point exception — don't block that case preventively without knowing it applies.

# Plan: WireGuard gateway as the single entry point to the lab

## Status

**Validated end-to-end 2026-08-08.** `deploy-wg-gateway` ran successfully (`vm-wg-gateway`, public IP, `wg0` active, keypair generated at boot). Admin peer and two team peers (`team1`, `team2`, one via automatic `add-team 2` and another via the new `wg-team-peer` subcommand for a team created before the gateway existed) tested from a real WireGuard client (WSL2 + `wireguard-tools`, Chromium browser via WSLg):

- Admin connected with `admin.conf` → `curl`/browser to `dmz-filesrv` (10.50.0.6:8080) and team1's building → **200/OK** on both.
- `team1.conf` → own building (`10.60.1.5:80`) → **302** (OK). `dmz-filesrv` → **200** (OK, iptables counter confirms).
- **Team↔team isolation confirmed with a real attack**, not just default config: manually edited `team1.conf`'s `AllowedIPs` to include `10.60.2.0/24` (simulating a team modifying its own file to try reaching another) and reconnected the tunnel — the packet did leave this time (WireGuard no longer blocked it on the client itself), but the `DROP` policy counter in `iptables -L FORWARD -v -n` on the gateway went up exactly on `curl` retries (10 → 15 packets) while local `curl` timed out — the real security layer (the gateway, not the client) blocked the attempt as designed. See "bug found and fixed" below for details of a real issue that did appear along the way.

An additional finding not anticipated in the original design: **the `AllowedIPs` on the *client* side in the server peer definition (not `IP route` routes) is itself a filtering layer in the WireGuard driver** — an attempt to force an OS route to a subnet not included in that `AllowedIPs` (`IP route add ... dev <iface>`) is instantly rejected by WireGuard's own kernel before leaving the network, the packet never reaching the gateway. Only by editing the `.conf`'s real `AllowedIPs` does the real access control (the gateway's iptables) get tested. Good to know for any future tests of this kind — a bare `IP route add` isn't enough to simulate a bypass attempt.

## Motivation

Until now the lab is operated by entering directly with `az` to any subnet — there's no real "entry point", and nothing stops a team from reaching another team's subnet or `snet-mgmt`. `CLAUDE.md` and `docs/plans/network-segmentation-nsgs.md` already noted that the VPN connector was "pending, no design yet" and the `snet-wg-gateway` row/column of that document's NSG matrix stayed blank "until a VPN plan exists". This document is that plan.

Requirements it resolves:
1. A WireGuard VM in `snet-wg-gateway` (10.10.0.0/28, created by `up`, empty until now) as the only entry point to the lab, reachable from the internet.
2. `add-team <N>` automatically generates a new tunnel for that team, with access *only* to its own network (`snet-team<N>`) + the DMZ (the real CTF objective) — never to another team or `snet-mgmt`.
3. A separate admin tunnel with access to everything (`10.0.0.0/8`).
4. A WireGuard `.conf` automatically generated for each tunnel created, ready to deliver.

## Why not NSGs

`docs/plans/network-segmentation-nsgs.md` designs per-subnet access matrix (team↔team, team→DMZ, nobody→mgmt). That still applies unchanged to traffic *within* the VNet that doesn't go through the gateway. But the control this plan needs is finer-grained: per-tunnel-peer, not per-subnet (two teams share the same `snet-team<N>` "class" but need mutually exclusive access — an NSG can't express that without a per-team rule that would also need to sync with `add-team`'s lifecycle, duplicating what `add_team_subnet` already does). Instead, access control lives **on the gateway VM itself**, via `iptables`:

- WireGuard's server-side `AllowedIPs` (`wg set wg0 peer ... allowed-IPs ...`) only does *crypto-key routing* — defines which tunnel IP accepts packets from that peer. Says nothing about what it can reach on the other side.
- The actual destination limit comes from a rule `iptables -A FORWARD -s <tunnel_ip_of_peer> -d <allowed_cidr> -j ACCEPT`, one per allowed CIDR, with `iptables -P FORWARD DROP` as default at the end. This gets added once per peer, when it's created (`add-peer.sh.tpl`).

## Addressing

- WireGuard overlay `10.200.0.0/16` — exists only within the gateway's `wg0` interface, never registered as an Azure subnet (no route tables/UDR touched). Traffic leaving `wg0` toward the VNet is masqueraded (`iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE`), so team services see traffic as if it came from the gateway's own IP in `snet-wg-gateway` — no need for Azure to know about `10.200.0.0/16`.
- Gateway's `wg0`: `10.200.0.1/16`.
- Admin peer: `10.200.0.2/32`, allowed destination `10.0.0.0/8` (everything).
- Peer `team<N>`: `10.200.<N>.2/32` (same number as `snet-team<N>`), allowed destination `10.60.<N>.0/24` + `10.50.0.0/24` + `10.51.0.0/24` (both DMZ).

## Implemented pieces

- `yamls/wg-gateway/cloud-init.yaml` — `vm-wg-gateway` boot: installs `wireguard`, `wireguard-tools`, `iptables-persistent`, `qrencode`; enables `ip_forward`; generates the server keypair *on boot itself* (necessary because `wg-quick` requires `PrivateKey` defined to bring up `wg0` — can't defer to a later step without first boot failing); leaves `wg0` with `PostUp`/`PostDown` (MASQUERADE + `FORWARD DROP`) but **without peers**.
- `yamls/wg-gateway/remote/init-server-keys.sh` — idempotent, run via `run-command` when needing to re-fetch the server pubkey (caches nothing locally on purpose, see below).
- `yamls/wg-gateway/remote/add-peer.sh.tpl` — `envsubst` template (`${PEER_NAME}`, `${TUNNEL_IP}`, `${ALLOWED_CIDRS}`), resolved **locally** before sending complete as a single string to `az vm run-command invoke` (same pattern as the base64 one-liner already tested in `create_wiki_vm`). Idempotent: reuses keypair if it exists, doesn't duplicate the `[Peer]` in `wg0.conf` (guard `# PEER:<name>`), `iptables -C` before `-A`.
- `yamls/templates/wg-client.conf.tpl` + `yamls/generate-wg-client.sh` — generate `yamls/generated/wg-clients/<name>.conf` (gitignored, contains the peer's private key).
- `lab-azure.sh`: `create_wg_nsg`, `deploy_wg_gateway`, `create_wg_peer`, `create_wg_team_peer` (the last one called from the end of `deploy_team()`, **guarded and non-blocking**: if `vm-wg-gateway` doesn't exist, `add-team` still works the same — just warns that team stays without tunnel until running `deploy-wg-gateway` and repeating). New "WireGuard Gateway" section in `status()`. New `deploy-wg-gateway` subcommand.
- **Deliberately not included in `test_deploy()`** (`./lab-azure.sh test [N]`) — still a quick smoke test of infra without VPN; nothing from the CTF's core depends on VPN for a team to already be deployable/attackable within the VNet.

## Bug found and fixed (first real run)

Missing was an `iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT` rule in `wg0.conf`'s `PostUp`. Without it, per-peer rules (`-s <tunnel_ip> -d <cidr> -j ACCEPT`) only cover outbound (client → destination); the reply arrives already unmasqueraded by conntrack (source = real destination IP, e.g., `10.50.0.6`, not the client's tunnel IP) and matches no rule — falls to `DROP` by default. Symptom observed: successful WireGuard handshake, but any TCP connection died after the first packet (`curl` timing out, `DROP` counter rising while the peer's `ACCEPT` counter stayed stuck). Fixed live on `vm-wg-gateway` (rule inserted + `netfilter-persistent save`), in its `/etc/wireguard/wg0.conf` (so it survives a reboot), and in `yamls/wg-gateway/cloud-init.yaml` (so future gateways don't repeat the bug).

The `./lab-azure.sh wg-team-peer <N>` subcommand was also added — necessary because `team1` had been deployed before the gateway existed (the non-blocking guard on `create_wg_team_peer` activated at that point) and there was no way to generate its tunnel retroactively without repeating all of `add-team`.

## Confirmed risks resolved in the first run

1. ~~How to invoke `run-command` for `add-peer.sh`~~ — worked exactly as designed (complete multi-line script as a single `--scripts`), no adjustments.
2. ~~Network interface assumed to be `eth0`~~ — confirmed correct on the image (`Ubuntu2204`).
3. ~~`iptables-persistent` with non-interactive debconf~~ — installed without hanging.
4. ~~Negative tests for team↔team isolation~~ — validated with a real bypass attempt (see above), including discovery of the `RELATED,ESTABLISHED` bug that would have gone unnoticed without this test.

## Risks still open

1. Each peer's private key is generated on the VM and travels back through `az vm run-command invoke`'s output channel (TLS encrypted, but logged in Azure Activity Log) instead of being generated locally and never leaving the VM. Conscious decision to not depend on having `wireguard-tools` installed on the operator's machine — trade-off, not oversight.
2. Not tested: isolation toward `snet-mgmt` (still empty, no services) nor behavior after a real reboot of `vm-wg-gateway` (persistence in `wg0.conf`/`netfilter-persistent` is written but never forced a restart to confirm it).

## Verification (first real run, in order)

```bash
# 1. wg0 active after boot
az vm run-command invoke -g rg-ctf-semana-ingenieria-test -n vm-wg-gateway --command-id RunShellScript \
  --scripts "systemctl is-active wg-quick@wg0 && wg show wg0" \
  --query "value[0].message" -o tsv | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}'

# 2. Correct iptables skeleton (DROP + MASQUERADE) before any peer
az vm run-command invoke -g rg-ctf-semana-ingenieria-test -n vm-wg-gateway --command-id RunShellScript \
  --scripts "iptables -L FORWARD -v -n; echo ---; iptables -t nat -L POSTROUTING -v -n" \
  --query "value[0].message" -o tsv | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}'

# 3. deploy-wg-gateway creates the admin peer server-side
./lab-azure.sh deploy-wg-gateway
az vm run-command invoke -g rg-ctf-semana-ingenieria-test -n vm-wg-gateway --command-id RunShellScript \
  --scripts "wg show wg0 peers" --query "value[0].message" -o tsv \
  | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}'

# 4. End-to-end from the operator's machine with admin.conf (requires local wireguard-tools)
sudo wg-quick up ./yamls/generated/wg-clients/admin.conf
curl -s http://<dmz-filesrv-IP>:8080/     # should work (admin reaches everything)
sudo wg-quick down ./yamls/generated/wg-clients/admin.conf

# 5. add-team 2 (to have two teams) and test isolation with team1.conf -- THE KEY TEST
./lab-azure.sh add-team 2
sudo wg-quick up ./yamls/generated/wg-clients/team1.conf
curl -s http://<team1-webapp-IP>:PORT/                 # should work (its own network)
curl -s http://<dmz-filesrv-IP>:8080/                # should work (DMZ allowed)
curl -s --max-time 5 http://<team2-webapp-IP>:PORT/     # should fail/timeout (blocked)
sudo wg-quick down ./yamls/generated/wg-clients/team1.conf
```

## Open / not decided

- Single admin peer for now (not a multi-admin system) — sufficient for the current single operator, expandable later if needed.
- No command for peer revocation/removal — wasn't requested, and the lab's lifecycle today is "everything destroyed with `down`", not selective removal.
- Cost: the gateway VM (with public IP) stays running indefinitely except manual shutdown (`az vm deallocate`) — like `vm-wiki`, decide whether to shut it off outside test windows.
- `wg show wg0` doesn't label peers by name (only pubkey) — acceptable for a first version; a more readable table would need to cross-reference against `wg0.conf`'s `# PEER:<name>` comments, not implemented yet.

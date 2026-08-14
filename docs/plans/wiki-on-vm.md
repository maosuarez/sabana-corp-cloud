# Plan: Move dmz-wiki + dmz-wiki-db to a VM with docker-compose

## Status

**Validated end-to-end 2026-08-08.** Quota unblocked after upgrade to Pay-As-You-Go (`StandardDsv7Family`, 10 vCPUs in eastus2). `./lab-azure.sh deploy-wiki-vm` ran successfully: `vm-wiki` (`Standard_D2s_v7`, `snet-dmz-vm`, IP `10.51.0.4`) deployed, cloud-init installed Docker, `docker compose up -d` brought up `wiki` (Up, no restart) and `wiki-db` (healthy) — s6-overlay starts fine with real PID 1, confirming the diagnosis of why it failed in ACI. `curl http://localhost` on the VM returns 302 (redirect to `/login`, normal BookStack behavior). Pending risk from the previous section also verified: cross-subnet routing `snet-dmz-vm` → `snet-dmz-shared` works without NSGs (ping and `curl` to `dmz-filesrv:8080` from the VM return 200/OK).

`lab-azure.sh:deploy_dmz()` no longer deploys `dmz-wiki`/`dmz-wiki-db` as ACI containers (removed from deployment loop) — wiki lives only in `vm-wiki` now.

Real pending item: `az vm run-command invoke` did work (didn't have to fall back to SSH + `nsg-jumpbox`). Only left to do: validate wiki from a real browser (via VPN flow, not yet implemented) and decide whether to shut down the VM off-hours (`az vm deallocate`) to not accumulate cost.

Historical (blocking issue already resolved, kept for context):

Scripts written (`yamls/templates/wiki-vm-compose.yml.tpl`, `yamls/generate-wiki-vm.sh`, `yamls/wiki-vm/cloud-init.yaml`, `lab-azure.sh deploy-wiki-vm`) but **NEVER TESTED** — the quota blocking (see below) turned out harder than it looked when writing the first version of this document: it's not that a request is missing, it's that **Azure for Students is ineligible to request VM quota increases at all** (confirmed 2026-08-02, neither self-service nor support ticket — Azure's form says explicitly: "Your subscription isn't eligible for a quota increase. To request a quota increase, first upgrade to a Pay-As-You-Go subscription"). All VM families with default quota assigned (Basic A, Standard A0-A7, B-series, D v2/v3/v4) turned out to be `SkuNotAvailable` (capacity restriction) on deployment attempt — not usable regardless. The only family confirmed deployable (`Standard_D2s_v7`, `StandardDsv7Family` family) has quota 0 and can't be increased.

Two paths to unblock, not yet decided:
1. Upgrade subscription to Pay-As-You-Go (billing decision, not made).
2. Abandon the VM for this case and run WireGuard/wiki in Azure Container Instances instead of VM (ACI supports adding `NET_ADMIN` capability to a Linux container — unconfirmed if it's enough to create the TUN interface WireGuard needs).

Scripts in this section are left written and documented to not repeat design work when either path unlocks, but **no one has run them**. The lab's Azure account was completely cleaned (`./lab-azure.sh down`) on 2026-08-02, so there's not even infrastructure alive to validate them against right now.

## Motivation

`dmz-wiki` (BookStack from `linuxserver/bookstack`) doesn't run on ACI: the image uses s6-overlay v3, which requires being PID 1 in its own process namespace, and ACI container groups integrated into a VNet (`subnetIds`) don't guarantee that — startup always fails with `s6-overlay-suexec: fatal: can only run as pid 1`, ExitCode 100, around ~6s. Confirmed deterministically against unmodified real YAML (see project memory `aci_platform_limitations` / `dmz_wiki_blocked`). Not a config bug — it's an ACI platform limitation, not fixable from the Dockerfile or wiki YAML.

Alternative evaluated and rejected for now: rebuild BookStack from scratch without s6-overlay (same pattern as `filesrv`/`wiki-db`, custom baked image). Valid but more work than simply running the `docker-compose.yml` that `sabana-corp-dmz` already has and which never depended on ACI.

One move (wiki + wiki-db to a VM, via docker-compose) solves three issues at once:

1. **s6-overlay works.** Plain Docker on a VM gives real PID 1 to the entrypoint — without rebuilding BookStack or hunting for an alternative image/tag without s6.
2. **The `wiki_bookstack_config:/config` volume returns.** Closes the persistence gap documented in `yamls/README.md` ("Persistence — pending for `wiki`"): today, without a volume, BookStack loses its keys/config if the ACI container restarts.
3. **The internal `wiki_backend` network returns.** In the original `docker-compose.yml`, `wiki-db` is only reachable from `wiki` via an internal bridge network (`internal: true`). Today on ACI, `dmz-wiki-db` is exposed directly on `snet-dmz-shared` (10.50.0.4:3306) without that isolation. On the VM, docker-compose restores the isolation as designed.

The rest of the DMZ and team1 (18 containers already running on ACI) stay the same, untouched. Only these two services move.

## Resolved question: can the VM go in `snet-dmz-shared`?

**No.** `snet-dmz-shared` is delegated to `Microsoft.ContainerInstance/containerGroups` (`az network vnet subnet update --delegations ...`, see `lab-azure.sh:delegate_dmz_subnet`). Subnet delegation in Azure is exclusive: once delegated to a service, that subnet only accepts resources of that type — a VM's NIC cannot be deployed there. The attempt would fail with a delegation conflict error.

**Resolved**: `snet-dmz-vm` (`10.51.0.0/24`) was created in `lab-azure.sh:create_vnet` — a parallel DMZ, not delegated, exclusive for services needing plain Docker instead of ACI. `snet-mgmt` (10.99.0.0/24) is reserved for the jumpbox/staff, not mixed with challenge services — cleaner separation if different NSG rules are needed for each later (see `docs/plans/network-segmentation-nsgs.md`: the draft rules already treat `snet-dmz-vm` the same as `snet-dmz-shared` — reachable from teams, no permission to initiate connections toward them — and `snet-mgmt` as the staff plane, unreachable for teams).

Routing between subnets of the same VNet already works by default in Azure (no peering or additional routes, see `yamls/README.md` "Access from the internal network") — a VM in `snet-dmz-vm` can reach `10.60.1.0/24` (team1) without extra configuration, and vice versa. No NSG blocks this today because none have been created on those subnets — see `docs/plans/network-segmentation-nsgs.md` for the design (not yet implemented) that would restrict it.

Additional advantage over current state: the VM has a **fixed private IP of its own** (assigned when creating the NIC), not a DHCP IP that needs to be read with `az container show --query ipAddress.IP` and patched with `sed` in the dependent's YAML (as today `deploy_dmz` does for `dmz-wiki-db` → `dmz-wiki`). That simplifies the `docker-compose.yml` (the compose's hostnames, `wiki-db`, still work via Docker's internal network within the same VM — they don't depend on Azure's IP at all).

## Current blocker: Azure for Students can't request VM quota

Confirmed 2026-08-02 with real `az vm create` tests (not just quota reads):

- Quota for `Microsoft.Compute` in `eastus2` (and verified that default allocation is identical across all tested regions: eastus, westus2, centralus, southcentralus, westus, westeurope) is **0** for all modern VM families (`StandardDsv7Family`/`StandardDsv6Family`/etc).
- Families that do have quota >0 by default (`basicAFamily`, `standardA0_A7Family`, `standardBSFamily`, `standardDv3Family`, `standardDv4Family`, ...) are **all** `SkuNotAvailable` (capacity restriction) when attempting a real `az vm create` — phantom quota, Azure has no capacity to deploy them on this subscription regardless.
- The only family confirmed actually deployable is `StandardDsv7Family` (`Standard_D2s_v7` passes validation until hitting the quota check), but is at 0.
- The quota increase form (`New Quota Request` / `Create a support request` → Service and subscription limits) responds explicitly: **"Your subscription isn't eligible for a quota increase. To request a quota increase, first upgrade to a Pay-As-You-Go subscription."** No support ticket can bypass this — it's an eligibility rule by offer type, not an approval issue.

This also blocks, besides the wiki, any other plan depending on a VM on this account (e.g., a dedicated WireGuard gateway) while it stays Azure for Students without upgrade.

## Implementation steps (written, not run — blocked on quota)

They already exist as code, not as a manual step list:

- `yamls/templates/wiki-vm-compose.yml.tpl` → `yamls/generate-wiki-vm.sh` generates `yamls/generated/wiki-vm-docker-compose.yml` (wiki + wiki-db + network `wiki_backend`, same images `maosuarez/sabanacorp-wiki` / `maosuarez/sabanacorp-wikidb` that DMZ already uses on ACI, same literal secrets as `dmz-wiki.yaml.tpl`/`dmz-wiki-db.yaml.tpl`).
- `yamls/wiki-vm/cloud-init.yaml` — installs Docker Engine + compose plugin on first boot via Docker's official script (`get.docker.com`).
- `lab-azure.sh:create_wiki_vm()` (command `./lab-azure.sh deploy-wiki-vm`) — creates `vm-wiki` in `snet-dmz-vm` without public IP or NSG, waits for Docker to be ready, and copies+brings up the compose via `az vm run-command invoke` (doesn't use SSH — avoids depending on `nsg-jumpbox`/public IP for initial admin).

Unverified risks because it never ran, to check the first time it's actually tested:

- **Internet output from `snet-dmz-vm`**: cloud-init needs to download Docker's script. Not confirmed if this subnet has default outbound (Azure is deprecating it for new subnets) — DMZ's ACI containers do pull images from Docker Hub today, but that tests nothing about `snet-dmz-vm` (different subnet, no containerInstance).
- **`az vm run-command invoke`** was never tested on this subscription — if it fails, need to fall back to SSH + `nsg-jumpbox` (already exists, see below) instead of run-command.
- After `docker compose up -d` runs the first time, still pending: verify access from an ACI container in the DMZ (`az container exec` to `dmz-decoy-nas` → `curl` to the VM's private IP), and update `yamls/templates/dmz-wiki*.yaml.tpl` + `yamls/README.md` to remove those two from the `deploy_dmz` flow once the VM replaces the equivalent ACI containers.

An NSG `nsg-jumpbox` with SSH (22) restricted to a public IP had been created (in an earlier test session, already destroyed along with the rest of the Resource Group on 2026-08-02) — if real SSH is needed instead of run-command, it needs to be recreated, the definition wasn't saved in this repo.

## Open / not decided

- Unblocking path: upgrade to Pay-As-You-Go (account owner's billing decision) vs. abandon the VM and move wiki/WireGuard to ACI with `NET_ADMIN` capability (unconfirmed if ACI supports creating TUN interfaces).
- Cost/lifetime of the VM once it exists: unlike ACI (pay-per-second, easy to tear down and recreate), a VM accumulates cost while running — decide whether to shut it down (`az vm deallocate`) outside test/event hours.
- Actual VM size (`WIKI_VM_SIZE`, default `Standard_D2s_v7` in the script): chosen only because it was the only family confirmed deployable in tests, not by actual wiki resource needs (BookStack + MariaDB for a one-day CTF is lightweight).

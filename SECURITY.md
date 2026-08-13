# Security Policy

## Scope

This repo deploys a CTF lab that is **intentionally vulnerable by design** — the team containers,
DMZ decoys, file share, and wiki are meant to be exploited by competitors. Findings like "the
webapp has SQLi" or "the file share allows anonymous access" are the challenges working as
intended, not security bugs. Don't report those here.

Do report:

- Anything that breaks isolation **outside** the intended CTF scope — e.g. a team's WireGuard
  tunnel reaching another team's subnet or `snet-mgmt`, a way to escape the VNet, or exposure of
  the operator's Azure credentials/secrets (`yamls/.env.secrets`, `DOCKERHUB_TOKEN`, etc.).
- Vulnerabilities in the orchestration scripts themselves (`lab-azure.sh`, `yamls/generate-*.sh`,
  the WireGuard/DNS/CTFd management scripts run via `az vm run-command`) — e.g. command injection
  via team names, secrets leaking into logs, or privilege issues on the management VMs
  (`vm-wg-gateway`, `vm-monitor`, `vm-ctfd`, `vm-wiki`).

## Reporting

Email **maosuarezbarrer@gmail.com** with a description and reproduction steps. Please don't open
a public GitHub issue for anything in scope above until it's been addressed.

# Plan: CTFd deployment and automation (flags/scoreboard)

## Status

**Phase 1 implemented in `../sabana-corp-CTFd` (2026-08-10, see note at end of document). Phase 2 — validated end-to-end against real Azure (2026-08-11, see final note): `vm-ctfd` deployed in `snet-dmz-vm`, `/setup` + admin + 5 challenges/flags loaded without any manual clicks.** Phase 3/4 — custom image CI (Docker Hub account pending), event operations — remain in design.

This document originated from a planning session (2026-08-10): understand the `../sabana-corp-CTFd` repository (fork of official CTFd) and decide how it fits into the infrastructure already existing in this repo, before writing a single line of automation.

Decision already made in the planning session (see "Competing Teams" below): **open self-registration**, without automated team creation.

## What is `../sabana-corp-CTFd`

Fork of [CTFd/CTFd](https://github.com/CTFd/CTFd) (`origin` → `Kings0401/CTFd-Sabanus`), nearly vanilla: 2 custom commits on top of upstream, both configuration, none touches Python app code (`CTFd/`):

1. `docker-compose.yml` parameterized with `.env` (port, `SECRET_KEY`, DB credentials) instead of the hardcoded `ctfd`/`ctfd`/`ctfd` that upstream includes.
2. Removed an inherited workflow (`mirror-core-theme.yml`) that doesn't apply to this fork.

No automation for challenges, flags, or teams yet — CTFd as cloned requires creating each challenge manually via admin UI. This plan closes that gap.

## Motivation

This repo's `CLAUDE.md` already lists **CTFd (flags and scoreboard)** as a shared service of `snet-dmz-shared`, marked "not yet implemented". The 5 real flags for the event already exist as environment variables in `yamls/.env.secrets` (template in `yamls/.env.secrets.example`) and feed the containers for each team — but no one has loaded them into a scoring platform. Without this, the event has no way to validate or score a flag submitted by a participant.

Two user questions define the scope of this plan:

1. How is CTFd deployed on Azure (Web App, ACI, or VM) in the best possible way?
2. How are the spaces (challenges) for each of the flags that already exist in `yamls/.env.secrets` **pre-created** in CTFd, and how are competing teams created?

## Design decision: deployment target — VM with docker-compose

Three options evaluated:

**a) Azure Web App for Containers.** Rejected. The Web App model is for public service by default (public HTTPS endpoint); hiding it behind the lab's internet-free VNet (this repo's architecture: "accessed only after breaking a captive portal and authenticating via VPN") would require VNet integration + private endpoint + disabling public access — more surface to maintain than simply adding a VM, which is exactly the pattern this repo has already solved twice. Also, Web App's support for "multi-container via docker-compose" (necessary for CTFd's real stack: app + MariaDB + Redis + nginx) is a semi-legacy mode of App Service, not Azure's current recommended approach for stateful stacks.

**b) Azure Container Instances**, following the repo's "1 YAML = 1 container = 1 IP" convention. Rejected for now. Like with the wiki (`docs/plans/wiki-on-vm.md`), CTFd requires: real persistence (MariaDB with event data, challenge attachment uploads) and internal network isolation (`app` talks to `db` and `cache` on a network that shouldn't be exposed in the shared VNet). Moving it to ACI would require (i) splitting CTFd's `docker-compose.yml` into 3-4 individual container YAML files, (ii) resolving the IP dependency between them with the same `sed` that `deploy_dmz`/`deploy_team` uses (fragile, one more maintenance step), and (iii) replacing local volumes with Azure Files so data survives a restart — three pieces of new complexity that option (c) doesn't need because CTFd **already brings its own complete, upstream-tested `docker-compose.yml`**.

**c) VM with `docker-compose` (the `docker-compose.yml` that the CTFd repo itself already brings).** Chosen. Exact same pattern as `vm-wiki` (`docs/plans/wiki-on-vm.md`) and `vm-monitor` (`docs/plans/observability-monitoring.md`): cloud-init installs Docker, compose is copied/generated, `docker compose up -d` via `az vm run-command invoke`. Zero new design pieces — it's replicating a pattern already validated end-to-end twice against real Azure, with the added advantage that here we don't even need to write the `docker-compose.yml` by hand: it already exists in `../sabana-corp-CTFd/docker-compose.yml`, maintained by upstream.

### Network location

`snet-dmz-shared` is delegated to `Microsoft.ContainerInstance/containerGroups` (exclusive, see `docs/plans/wiki-on-vm.md`) — a VM cannot go there, the same conflict the wiki had. Instead of creating a third subnet, **reuse `snet-dmz-vm` (`10.51.0.0/24`)**, which already exists exactly for this: "parallel DMZ for services that don't run in ACI". `vm-ctfd` would live alongside `vm-wiki` in the same subnet, without needing a new subnet or touching `create_vnet`.

Open question: a new VM (`vm-ctfd`) or coexist in `vm-wiki` running a second `docker-compose.yml`? **Separate VM recommended** — CTFd brings its own MariaDB and Redis; putting it in the same VM as the wiki's BookStack+MariaDB duplicates the Docker bridge network isolation pattern that each compose already handles on its own, gaining nothing except a bit of vCPU quota (there's headroom: 6/10 vCPU in use today according to `docs/plans/observability-monitoring.md` "Cost and quota").

## Design decision: how challenges/flags are pre-created

This is the heart of the user's question. Options evaluated:

**a) `ctfcli` (CTFd's official "challenges as code" tool).** Rejected. Its model is for challenges that **are** the content to upload (attachments, Docker image of the challenge itself, `challenge.yml` with `image:`/`build:`). Sabana Corp's "challenges" are not that — they're live infrastructure services (`webapp`, `database`, `linux-server`) that `lab-azure.sh` deploys on its own; in CTFd they only need to exist as **scoring entries** (name, category, description, flag). Adopting `ctfcli` would bring a format and workflow designed for a case that isn't ours, without solving anything a simple script won't solve better.

**b) CTFd import/export (`export_ctf`/`import_ctf`, backup in `.zip`).** Rejected as source of truth. It's a complete instance backup format (users, submissions, config), not a readable or git-diffable manifest — it doesn't fit with "templates + generators" (decision already recorded in this repo's `CLAUDE.md`). It can serve later as operational backup between event editions, but not as challenge definition.

**c) Custom script against CTFd's admin REST API (`/api/v1/challenges`, `/api/v1/flags`), idempotent, reading a versioned declarative manifest.** Chosen — same spirit as `generate-team.sh`/`generate-dmz.sh`: a declarative source of truth + a generator/applier, no manual state via UI.

### Manifest and seed design

- **Manifest** (`../sabana-corp-CTFd/challenges/challenges.yml`, lives in the CTFd repo, not this one): one challenge per flag, referencing the **name** of the flag variable (`FLAG_WEBAPP_XSS`), never its value.

  ```yaml
  - name: "Web App — Stored XSS"
    category: "Web Application"
    flag_env: FLAG_WEBAPP_XSS
    value: 100
    state: hidden   # visible only when staff publishes the event
    description: |
      ...
  - name: "Web App — LFI on attachments"
    category: "Web Application"
    flag_env: FLAG_WEBAPP_LFI
    value: 50
    state: hidden
  - name: "Database"
    category: "Database"
    flag_env: FLAG_DATABASE
    value: 100
    state: hidden
  - name: "Linux Server — root"
    category: "Linux Server"
    flag_env: FLAG_LINUXSERVER_ROOT
    value: 150
    state: hidden
  - name: "Linux Server — process flag"
    category: "Linux Server"
    flag_env: FLAG_LINUXSERVER_PROC
    value: 25
    state: hidden
  ```

  Points (`value`) and descriptions are the event organizer's responsibility, not this document — they remain as placeholders.

- **Seed script** (`../sabana-corp-CTFd/scripts/seed_challenges.py` or similar, in the CTFd repo): reads `challenges.yml`, reads actual flag values from `yamls/.env.secrets` (in **this** repo, gitignored — the script receives the path or already-exported variables, never hardcodes them), and calls CTFd's admin API (`Authorization: Token <admin_api_token>`) to create/update each challenge + its flag. Idempotent: if the challenge already exists (match by `name`), updates instead of duplicating — necessary because the script will run more than once (future event editions, point changes, typos in description).
- **Explicitly out of scope for the seed**: `PIVOT_SSH_PASSWORD` and `BOT_SECRET` are not scoring flags — they're progression secrets (terminology from `sabana-corp-network/CLAUDE.md`, "Rules for maintaining consistency between flags"). They don't generate a challenge in CTFd.
- **Challenges start hidden** (`state: hidden`). A second command from the same script (or a `--publish` flag) changes them to `visible` — separate "load content" from "open the CTF to the public" to avoid exposing challenge names/categories before the event starts.
- Admin token source — **automated 2026-08-10, see note at end**: `CTFD_PRESET_ADMIN_TOKEN` in `yamls/.env.secrets`, not an Access Token generated manually by staff. CTFd exposes `PRESET_ADMIN_TOKEN` exactly for this case (environment variable that acts as a token for a dynamically created admin) — it lives alongside other event secrets, never committed. See "Risks" below.

## Competing Teams — open self-registration (decided in this session)

In CTFd, a "team" (`user_mode=teams`) is just a scoring group: name + login password that participants choose themselves during registration, with no automatic relationship to `team1..teamN` on this repo's network. This is because the flags are **identical for all teams** (`yamls/.env.secrets` doesn't vary by `${TEAM}`, see `CLAUDE.md`) — CTFd doesn't need to know which subnet/WireGuard tunnel each participant is on to score their flag.

Decision: **open self-registration**, without new team creation automation. It's CTFd's default flow (`Setup` → `user_mode: teams`) and requires no script or pre-distributed credentials.

Configuration to define in CTFd's initial setup (once, via the UI, not automated — not worth a script for something done once per event edition):

- `user_mode: teams`, `registration_visibility: public`.
- `team_size`: member limit per team (define per event).
- `verify_emails`: probably `false` — closed event within a one-day university CTF, email verification friction adds nothing here.

**Operational note** (not a technical problem, just a note for the event staff): the team name a participant chooses in CTFd doesn't automatically match their `teamN` on the WireGuard tunnel/subnet. It's acceptable because the system doesn't need it, but it's good practice to ask each team — as an event instruction, not a technical control — to use their network number as their team name in CTFd, just so staff can cross-reference the scoreboard with the infrastructure at a glance if support is needed.

## CI/CD

Convention already established and documented in `sabana-corp-network/CLAUDE.md` ("CI/CD conventions"), which this plan adopts as-is to keep the 3 project repos consistent:

- Image build + push on every push to `main` (not on `release`, unlike the fork's current `docker-build.yml` — see finding below).
- Tags `<dockerhub-user>/<image>:latest` + `:<short-sha>`.
- Workflows never use real flag/secret values — only `.env.example`/dummy defaults; real secrets are injected on actual deployment, outside CI.

### Finding: inherited upstream CI is broken in this fork, unnoticed

`../sabana-corp-CTFd` has 7 workflows inherited from CTFd/CTFd. Of those, **6 never run**: `mariadb.yml`, `mysql.yml`, `mysql8.yml`, `postgres.yml`, `sqlite.yml`, `verify-themes.yml` are all activated with `branches: [master]` — the fork uses `main` as the default branch. No push to `main` or PR against `main` ever triggers them. Only two workflows actually run today:

- `lint.yml` — activated with `on: [push, pull_request]` without branch filter, it runs.
- `docker-build.yml` — activated with `on: release: types: [published]`, publishes `${GITHUB_REPOSITORY,,}` (today `kings0401/ctfd-sabanus`) to Docker Hub + GHCR using repo GitHub secrets `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` — runs only if someone publishes a GitHub Release, which has never happened in this fork.

Two pending decisions, not taken in this session (they're for the repo/event owner, not technical):

1. **What to do with the 6 dead workflows.** Options: (a) retarget to `main` to recover upstream test coverage for this fork, (b) delete them because this fork doesn't plan to actively merge from upstream CTFd and maintaining 5 different DB matrices (only deployed with MariaDB, see `docker-compose.yml`) adds no real value — consistent with project memory "docs must reflect tested reality: delete dead artifacts instead of documenting them".
2. **Target Docker Hub account.** `docker-build.yml` today publishes under the GitHub repo name (`kings0401/...`), not under `maosuarez` (the account the rest of the project uses for `sabanacorp-*`, see this repo's `CLAUDE.md`, "Design decision: templates + generators"). Define whether the CTFd image publishes to `maosuarez/sabanacorp-ctfd` (consistent with the rest) or stays in the `sabana-corp-CTFd` owner's account — affects which GitHub Actions secrets need configuring and in which account.

Concrete proposal for when the above is decided (not yet implemented): replace `docker-build.yml` with a `push to main` workflow like `sabana-corp-dmz/docker-publish.yml` / `sabana-corp-network/build-push.yml` — single job, no matrix (single image), tags `:latest` + `:<short-sha>`.

## Future integration with `lab-azure.sh`

Not yet implemented, just the skeleton of what would be needed to avoid repeating design when deciding to execute this:

- `deploy-ctfd-vm`: same pattern as `deploy-wiki-vm`/`deploy-monitor-vm` — creates `vm-ctfd` in `snet-dmz-vm`, cloud-init installs Docker, copies/generates the `docker-compose.yml` (using the image published by CI instead of building locally on the VM, faster and reproducible), variables from a new `CTFD_*` block in `yamls/.env.secrets` (port, `SECRET_KEY`, DB credentials — same pattern already used by the fork's `.env.example`).
- At the end of deployment: run `seed_challenges.py` via `az vm run-command invoke` (or from the operator, against the private IP via the admin tunnel) — same mechanism already used in this repo for anything touching a VM without SSH.
- `lab-azure.sh`'s `status` would gain a section for `vm-ctfd`, like it already has for `vm-wiki`/`vm-monitor`/gateway.

## Risks / Open items

- **Seed script admin token — RESOLVED (2026-08-10)**: `CTFD_PRESET_ADMIN_TOKEN` (`yamls/.env.secrets`) replaces manual Access Token generation. CTFd accepts it as an Access Token for an admin it creates on-the-fly if it doesn't exist (see `CTFd/utils/security/auth.py:lookup_user_token`/`generate_preset_admin`), so `create_ctfd_vm()` runs `seed_challenges.py` automatically without browser login. It's still the same secret level as an admin password — lives outside git, treat it like `MYSQL_ROOT_PASSWORD`.
- **The `/setup` wizard is also automated (2026-08-10)**: `PRESET_ADMIN_TOKEN` alone isn't enough — CTFd blocks *all* requests (including API) until `/setup` is complete (see `needs_setup()` in `CTFd/utils/initialization/__init__.py`), and that endpoint is an HTML form with CSRF tied to the browser session, not an API. Instead of scraping HTML, `scripts/seed_setup.py` (new, in `../sabana-corp-CTFd`) replicates the `/setup` view logic directly against CTFd models (`set_config` + create the `Admins`), running *inside* the `ctfd` container (`docker compose exec ctfd python3 -`, needs the CTFd package installed — unlike `seed_challenges.py`, which runs from the VM host with just `requests`+`PyYAML`). Sets `user_mode=teams`, `registration_visibility=public`, `verify_emails=false` (the "Competing Teams" decisions above); uses `CTFD_EVENT_NAME`/`CTFD_EVENT_DESCRIPTION`/`CTFD_TEAM_SIZE` (`yamls/.env.secrets`) and the same admin as `PRESET_ADMIN_TOKEN` (even if they run in any order, no duplicate account — both match by email). Idempotent: if `is_setup()` is already `true`, it touches nothing, so `deploy-ctfd-vm` is safe to re-run without resetting the name/admin from a previous edition.
- **Persistence between event editions**: CTFd stores submissions/scoreboard in its MariaDB. If `vm-ctfd` is destroyed with `./lab-azure.sh down` (deletes the entire Resource Group, project invariant), event history is lost unless `export_ctf` is done first — not yet decided if that's automated (cron on the VM, or manual step when closing the event).
- **CTFd `SECRET_KEY`**: signs sessions for all registered users (staff and participants). Rotating it invalidates active sessions — generate once per event edition and treat it as a secret, like the challenges' `JWT_SIGNING_SECRET`.
- **`vm-ctfd` size**: undecided, probably `Standard_D2s_v7` for consistency with `vm-wiki`/`vm-monitor`/`vm-wg-gateway`, not from actual load calculation (CTFd for a one-day event with dozens of teams is lightweight).
- **Who publishes the event (`state: hidden` → `visible`)**: decide if it's a seed script flag, a button in CTFd's UI (already exists, "Freeze"/native CTF start dates), or both — CTFd already has native CTF `start`/`end`, might not need anything new here beyond configuring them in initial setup.

## Event day runbook

Real commands, already tested against Azure (2026-08-11), so you don't have to reconstruct this flow from memory that day.

**Fresh deployment** (`vm-ctfd` doesn't exist yet):

```bash
export DOCKERHUB_USER="..."
export DOCKERHUB_TOKEN="..."
# yamls/.env.secrets must already have the CTFD_* block with REAL values, not changeme_*
# (CTFD_SECRET_KEY, CTFD_DB_PASSWORD, CTFD_DB_ROOT_PASSWORD, CTFD_PRESET_ADMIN_PASSWORD,
# CTFD_PRESET_ADMIN_TOKEN, CTFD_EVENT_NAME) -- see "Risks" above.

CTFD_SEED_PUBLISH=1 ./lab-azure.sh deploy-ctfd-vm   # without this, challenges stay hidden
```

Without `CTFD_SEED_PUBLISH=1`, the 5 challenges load but with `state=hidden` — **this is by design, not a bug**: `/challenges` looks empty even when logged in as admin until they're published (see "Manifest and seed design" above, "load content" vs. "open the CTF"). It was confused with a real error during this session's validation — if it happens again, it's not a sign something broke.

**Publish (or republish) without recreating the VM**, if it's already deployed and you just need to change challenges from hidden to visible (or reload a change in `challenges.yml`/flags):

```bash
TOKEN="$(grep ^CTFD_PRESET_ADMIN_TOKEN= yamls/.env.secrets | cut -d= -f2-)"
VM_IP="$(az vm list-ip-addresses -g rg-ctf-semana-ingenieria-test -n vm-ctfd \
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)"
az vm run-command invoke --resource-group rg-ctf-semana-ingenieria-test --name vm-ctfd \
  --command-id RunShellScript \
  --scripts "cd /opt/ctfd && CTFD_URL=http://localhost CTFD_API_TOKEN='${TOKEN}' python3 seed/seed_challenges.py --manifest seed/challenges.yml --env-file seed/flags.env --publish" \
  --query "value[0].message" --output tsv
```

Idempotent (matches by `name`, no duplication) — safe to run multiple times. Omit `--publish` if you want to reload content without changing current visibility.

**Verify it's responding** (in case internal DNS doesn't resolve on the client — WireGuard split-DNS isn't reliable on Linux, see `docs/plans/internal-dns.md`):

```bash
google-chrome http://ctfd.dmz.sabanacorp.internal   # preferred, via internal DNS
google-chrome http://<vm-ctfd private IP>/challenges   # direct fallback via IP
```

Admin login: `CTFD_PRESET_ADMIN_EMAIL` / `CTFD_PRESET_ADMIN_PASSWORD` (`yamls/.env.secrets`).

**Status, if something looks odd**:

```bash
./lab-azure.sh status   # "DMZ-VM" section: vm-ctfd + status of the 4 containers
az vm run-command invoke -g rg-ctf-semana-ingenieria-test -n vm-ctfd \
  --command-id RunShellScript --scripts 'docker compose -f /opt/ctfd/docker-compose.yml logs --tail 100 ctfd' \
  --query "value[0].message" -o tsv
```

**Watch out with `--output table`/relying on `az vm run-command invoke` exit code**: it doesn't reflect if the remote script failed (see note below, bug 1) — always add `--query "value[0].message" --output tsv` and read the text if something doesn't add up.

## Proposed phases

### Phase 1 — Manifest + challenge seed script

- `challenges/challenges.yml` in `../sabana-corp-CTFd` with the 5 current flags.
- `scripts/seed_challenges.py`, idempotent, against CTFd's admin API.
- Document in `../sabana-corp-CTFd/CLAUDE.md` how to generate the admin Access Token the first time.

### Phase 2 — Real VM

- `deploy-ctfd-vm` in `lab-azure.sh`, `vm-ctfd` in `snet-dmz-vm`, validated end-to-end against real Azure (same bar as wiki/monitor: not marked "implemented" until actually run).

### Phase 3 — Custom image CI

- Decide target Docker Hub account and what to do with the 6 broken inherited workflows.
- `push to main` workflow like `sabana-corp-network`/`sabana-corp-dmz`.

### Phase 4 — Event operations

- Publish/unpublish challenges, `export_ctf` before a `down`, and (if decided) align CTFd team name ↔ `teamN` as an event instruction, not a technical control.

**Phase 1 is the minimum to load real flags without manual clicks.** Phase 2 is what makes it deployable. Phase 3/4 are operational hygiene, they don't block a first test event.

## Note (2026-08-10) — Phase 1 and part of Phase 3 implemented in `../sabana-corp-CTFd`

Implementation session in `../sabana-corp-CTFd` (not in this repo). Nothing run against real Azure yet — all tested locally (dry-run of seed, `yaml`/`docker compose config` valid). To continue from this side (`sabana-corp-cloud`), here's what already exists and under what contract:

**Phase 1 — manifest + seed script (done, matches the design above):**

- `../sabana-corp-CTFd/challenges/challenges.yml` — the 5 flags from this document's table, one entry per challenge, `flag_env: FLAG_*` (never the value). `value`/`description` are placeholders set in this session — pending for the event organizer to adjust.
- `../sabana-corp-CTFd/scripts/seed_challenges.py` — idempotent (match by `name`/`challenge_id` against `/api/v1/challenges` and `/api/v1/flags`), validates that **all** `FLAG_*` from the manifest are in the environment before calling the API (aborts without creating anything if any is missing, lists only the names). Two ways to inject flags: variables already exported in the process, or `--env-file <path>` (does `setdefault`, doesn't override what's already there) — designed exactly to point at `yamls/.env.secrets` in this repo. Own flags: `--dry-run` (validates without calling the API), `--publish` (also marks everything `visible`).
- `../sabana-corp-CTFd/scripts/requirements.txt` — `requests` + `PyYAML`, separate from the app's `requirements.txt` because the script doesn't run inside the CTFd container.
- Requires `CTFD_URL` + `CTFD_API_TOKEN` in the environment (not in the `--env-file` of flags, though the loader would accept them there). **Automated 2026-08-10** (see note at the end): `create_ctfd_vm()` passes `CTFD_URL=http://localhost` (runs on the `vm-ctfd` host) and `CTFD_API_TOKEN=$CTFD_PRESET_ADMIN_TOKEN` — no need for manual login → Settings → Access Tokens anymore.

**Part of Phase 3 — custom image CI (done, Docker Hub account decision still pending on your side):**

- The 6 broken inherited workflows (`mariadb.yml`, `mysql.yml`, `mysql8.yml`, `postgres.yml`, `sqlite.yml`, `verify-themes.yml`) and the original `docker-build.yml` (gated to `release: published`) were **removed**.
- `../sabana-corp-CTFd/.github/workflows/deploy.yml` — new, `on: push` to `main` + `workflow_dispatch`, build+push `linux/amd64` to `<DOCKERHUB_USERNAME>/sabana-corp-ctfd:latest` and `:<sha>`. **Requires you to inject the `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` repo secrets** on GitHub — today the workflow exists but would fail at the login step because those secrets aren't configured. Fixed image name `sabana-corp-ctfd` under whatever namespace `DOCKERHUB_USERNAME` is (the pending decision of "which account to publish to" now resolves itself based on what account you put in that secret, no more code to change).

**Bonus outside the original plan scope, useful for Phase 2:**

- `../sabana-corp-CTFd/docker-compose.prod.yml` — production variant of CTFd's compose: does `pull` of `${DOCKERHUB_IMAGE}:${IMAGE_TAG}` (the image published by `deploy.yml`) instead of `build: .`, and doesn't mount source code as a volume. It's exactly what `deploy-ctfd-vm` should copy/generate into `vm-ctfd` according to the design of "Future integration with `lab-azure.sh`" above.
- `../sabana-corp-CTFd/.env.production.example` — template for the variables that compose needs (`DOCKERHUB_IMAGE`, `SECRET_KEY`, `DB_*`, `TRUSTED_HOSTS`, `PRESET_ADMIN_*`, etc.). Maps 1:1 to what should come out of a future `CTFD_*` block in `yamls/.env.secrets` (mentioned in "Future integration with `lab-azure.sh`" above) — that block doesn't yet exist in `yamls/.env.secrets.example` of this repo.

**What's needed for Phase 2 to run (all on this repo side, `sabana-corp-cloud`):**

1. Add a `CTFD_*` block to `yamls/.env.secrets.example` (port, `SECRET_KEY`, DB credentials, `DOCKERHUB_IMAGE`) following the format of `.env.production.example` above.
2. `deploy-ctfd-vm` in `lab-azure.sh`: create `vm-ctfd` in `snet-dmz-vm`, cloud-init with Docker, copy `docker-compose.prod.yml` + `.env` generated from `yamls/.env.secrets`, `docker compose up -d` via `az vm run-command invoke` (same pattern as `deploy-wiki-vm`/`deploy-monitor-vm`).
3. At the end of that deployment, invoke `seed_challenges.py --env-file yamls/.env.secrets --publish` (or without `--publish` if the event hasn't started yet) against `vm-ctfd`'s private IP — requires resolving first how to get `CTFD_API_TOKEN` without manual intervention (open point from Phase 1 above) or accept that this step stays manual.
4. Configure the `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` secrets in the `sabana-corp-CTFd` GitHub repo so that `deploy.yml` publishes for real.

## Note (2026-08-10) — Phase 2 written in `sabana-corp-cloud`, not yet tested against Azure

Implementation session in this repo, closing the 4 points of "What's needed for Phase 2 to run" above (except point 4, which is on the `sabana-corp-CTFd`/GitHub side, outside this repo). Everything tested locally (`yamls/generated/ctfd/docker-compose.yml` render with `envsubst`, validated as YAML) — **nothing deployed against real Azure yet**, so `vm-ctfd` still doesn't exist.

**New files:**

- `yamls/templates/ctfd-compose.yml.tpl` — adapted from `../sabana-corp-CTFd/docker-compose.prod.yml` (nginx + ctfd/gunicorn + MariaDB + Redis), without docker-compose's `${VAR:-default}` defaults (`envsubst` doesn't understand them — they were removed and defaults now live in the generator).
- `yamls/ctfd-vm/cloud-init.yaml` — same cloud-init as `yamls/wiki-vm/cloud-init.yaml` (Docker Engine + compose plugin).
- `yamls/ctfd-vm/conf/nginx/http.conf` — vendored exactly from `../sabana-corp-CTFd/conf/nginx/http.conf` (static, no variables).
- `yamls/generate-ctfd-vm.sh` — generates `yamls/generated/ctfd/{docker-compose.yml, conf/nginx/http.conf}`. Unlike `generate-wiki-vm.sh` (literal secrets), reads the `CTFD_*` block from `yamls/.env.secrets` — same mechanism as `generate-team.sh`. Image resolved as `${DOCKERHUB_USER}/sabana-corp-ctfd:${CTFD_IMAGE_TAG:-latest}`.

**Edited files:**

- `yamls/.env.secrets.example` — new `CTFD_*` block (`CTFD_SECRET_KEY`, `CTFD_DB_NAME`, `CTFD_DB_USER`, `CTFD_DB_PASSWORD`, `CTFD_DB_ROOT_PASSWORD`, `CTFD_PRESET_ADMIN_*`). The real `yamls/.env.secrets` (gitignored) also received the block, with the same `changeme_*` placeholders — needs to be filled with real values before deployment.
- `yamls/generate-dns-hosts.sh` — the `dmz` and `all-from-azure` cases now also resolve `vm-ctfd`'s IP (if it exists) and register `ctfd.dmz.${LAB_DOMAIN}` (alias `scoreboard.dmz`), same pattern as `wiki.dmz`.
- `lab-azure.sh` — new `create_ctfd_vm()` function (same pattern as `create_wiki_vm()`: creates `vm-ctfd` in `snet-dmz-vm`, waits for Docker via cloud-init, pushes the tar+base64 bundle via `run-command`, `docker compose up -d`, registers DNS). New `deploy-ctfd-vm` command, new section in `status()`, usage string and header comment updated.

**What's needed to run this for real (not resolved in this session):**

1. Fill `yamls/.env.secrets` (block `CTFD_*`) with real values, not `changeme_*` placeholders (now includes `CTFD_PRESET_ADMIN_TOKEN`, `CTFD_EVENT_NAME` — see next note).
2. Confirm that the image `${DOCKERHUB_USER}/sabana-corp-ctfd:latest` already exists on Docker Hub (user indicated yes, under their account) and that `DOCKERHUB_USER` points to that account when running `./lab-azure.sh deploy-ctfd-vm`.
3. Run `./lab-azure.sh deploy-ctfd-vm` against real Azure and validate end-to-end (startup of the 4 services, `/setup` + Access Token + challenge loading already automated, see next note — real run still pending) before marking Phase 2 as implemented.
4. Point 4 of the original "What's needed" (secrets `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` in the `sabana-corp-CTFd` GitHub repo) is still pending and independent of this repo.

## Note (2026-08-10, continued) — full automation of first boot (setup + admin token)

Same day, same session: the gap marked above as manual (admin login → Settings → Access Tokens) was closed, and a larger undocumented gap was found and closed — CTFd blocks *all* requests (including API) until the `/setup` wizard completes (see `needs_setup()` in `CTFd/utils/initialization/__init__.py`), so an admin token alone isn't enough to run `seed_challenges.py` without human intervention.

**New files:**

- `../sabana-corp-CTFd/scripts/seed_setup.py` — replicates the `/setup` view logic (create admin, set `user_mode`/visibility/event name, mark `config['setup']=true`) directly against CTFd models, without going through the HTML form (which requires a CSRF nonce tied to the browser session — automating it with a generic HTTP client would have meant scraping that nonce from HTML, fragile). That's why it runs *inside* the `ctfd` container (`docker compose exec -T ctfd python3 - < seed/seed_setup.py`), not from the VM host like `seed_challenges.py` — needs the CTFd package installed and Flask/DB context, not just `requests`/`PyYAML`. Idempotent (`if is_setup(): return`), and if the admin created by `PRESET_ADMIN_TOKEN` already exists (same email), it doesn't duplicate.

**Edited files (`sabana-corp-cloud`):**

- `yamls/templates/ctfd-compose.yml.tpl` — added `PRESET_ADMIN_TOKEN` (CTFd accepts it as an Access Token for an admin it creates on-the-fly, see `CTFd/utils/security/auth.py`) and `CTFD_EVENT_NAME`/`CTFD_EVENT_DESCRIPTION`/`CTFD_TEAM_SIZE` (not CTFd's native variables, read by `seed_setup.py`) to the `ctfd` service's `environment`.
- `yamls/generate-ctfd-vm.sh` — `CTFD_PRESET_ADMIN_NAME/EMAIL/PASSWORD` changed from optional to required (automatic seed depends on a valid admin existing), added `CTFD_PRESET_ADMIN_TOKEN` (required) and `CTFD_EVENT_NAME` (required)/`CTFD_EVENT_DESCRIPTION`/`CTFD_TEAM_SIZE` (optional); also now vendors `seed_setup.py` from `$CTFD_REPO_DIR` alongside other `seed/` files.
- `yamls/.env.secrets(.example)` — new variables `CTFD_PRESET_ADMIN_TOKEN`, `CTFD_EVENT_NAME`/`CTFD_EVENT_DESCRIPTION`/`CTFD_TEAM_SIZE`. **Watch the quotes**: `.env.secrets` is sourced with `source` in bash (not a real `.env` parser) — a value with spaces like `CTFD_EVENT_NAME` must be quoted (`CTFD_EVENT_NAME="Sabana Corp CTF"`) or `source` breaks interpreting the rest as a command. Already fixed in both files; keep this in mind if adding more space-containing variables to this file in the future.
- `lab-azure.sh` — `create_ctfd_vm()` now runs, in order, `seed_setup.py` (inside the container) and then `seed_challenges.py` (from the VM host), between the "CTFd responds" check and the final message. Cloud-init for `vm-ctfd` gains `python3-pip` (already there, no changes this time).

**Validated locally**: `./yamls/generate-ctfd-vm.sh` runs clean with test `DOCKERHUB_USER`, the resulting `docker-compose.yml` is valid YAML with the 4 new variables resolved, and vendored `seed_setup.py` passes syntax check. **Nothing run against real Azure** — `vm-ctfd` still doesn't exist, still step 3 from the list above.

## Note (2026-08-11) — Phase 2 validated end-to-end against real Azure, three bugs found and fixed

`./lab-azure.sh deploy-ctfd-vm` ran against the real lab. First run finished with exit 0 and a "success" message — but **that didn't mean it actually worked**: post-deploy manual verification (reading `value[0].message` from each `run-command invoke` directly instead of trusting `--output table`/`az` exit code) found two real bugs, both fixed and re-validated against the same VM (without recreating it, see project memory on live-applying):

1. **`az vm run-command invoke` doesn't propagate the remote script's exit code.** Confirmed with a control `--scripts "exit 1"`: `az` returns exit 0 and `"code": "ProvisioningState/succeeded"` anyway. The real result (success or traceback) lives only in the text of `value[0].message`. The first version of `create_ctfd_vm()` relied on `az`'s exit code for the "does CTFd respond?" loop and used `--output table` (which showed nothing useful) to invoke `seed_setup.py`/`seed_challenges.py` — neither would have failed the deployment if the remote script crashed. Fixed: **every** `run-command invoke` whose result matters now captures `--query "value[0].message" --output tsv`, always prints it (no silent output), and decides success/error by inspecting the text (HTTP code for health check, a known success marker for each script) — not `az`'s exit code. This rule applies to any new `run-command` added later, not just CTFd ones.
2. **`TRUSTED_HOSTS` didn't include `localhost`.** `seed_challenges.py` and the health check hit CTFd at `http://localhost` (inside `vm-ctfd`, via nginx), but `TRUSTED_HOSTS` only had `ctfd.dmz.sabanacorp.internal` — Werkzeug returned `500 SecurityError: Host 'localhost' is not trusted` for any request with that Host header (see `CTFd/__init__.py:create_url_adapter`). `seed_setup.py` wasn't affected (uses no HTTP, writes directly against models), but `seed_challenges.py` was — first run's challenge loading **never actually happened**, though the deployment reported success. Fixed in `generate-ctfd-vm.sh`: `TRUSTED_HOSTS="ctfd.dmz.${LAB_DOMAIN},localhost"` (CTFd uses comma separation, see `CTFd/config.py`).

**Minor side effect, not a bug**: `GET /` returns 404 (not 200) because `seed_setup.py` deliberately doesn't create the `index` page that the original `/setup` view does (considered unnecessary for the CTF — participants' real flow is `/challenges`/`/login`, not the home). That's why the health check points to `/api/v1/challenges` (returns 302, not 404) instead of `/`.

**Real run result, verified directly against `vm-ctfd` (not just deployment logs)**: all 4 containers (`ctfd`, `nginx`, `db`, `cache`) running; `seed_setup.py` confirmed idempotent (`CTFd is already configured` on a second manual run); 5 challenges loaded with `state=hidden` and stable IDs between runs (`seed_challenges.py` also confirmed idempotent); `ctfd.dmz.sabanacorp.internal` resolves to `10.51.0.4` from `dns-check`. **Phase 2 is validated end-to-end — same bar as wiki/monitor.** Real pending item: this operator's `.env.secrets` still has several `changeme_*` values (`CTFD_SECRET_KEY`, `CTFD_DB_PASSWORD`, `CTFD_DB_ROOT_PASSWORD`, `CTFD_PRESET_ADMIN_PASSWORD`, `CTFD_PRESET_ADMIN_TOKEN`) — this was a test run, need to rotate to real values before the actual event (same care as documented for `SECRET_KEY`/`MYSQL_ROOT_PASSWORD` above).

**Third bug, found by user actually browsing (same session)**: accessing `http://10.51.0.4` directly by IP (instead of FQDN) also gave `500 SecurityError: Host '10.51.0.4' is not trusted` — same mechanism as bug 2, but with a different Host header. Relevant because WireGuard split-DNS **is not reliable on Linux clients** (see `docs/plans/internal-dns.md`), so accessing by IP isn't a rare edge case, it's a real path. Fixed: `create_ctfd_vm()` in `lab-azure.sh` now gets `vm-ctfd`'s private IP immediately after `az vm create` (before it was requested later, after generating the bundle) and passes it to `generate-ctfd-vm.sh` as `CTFD_VM_IP`, which adds it to `TRUSTED_HOSTS` — `ctfd.dmz.${LAB_DOMAIN},localhost,${CTFD_VM_IP}`. Applied live to the already-running `vm-ctfd` (regenerate bundle + `docker compose up -d`, no VM recreation) and verified with `curl -H 'Host: 10.51.0.4'` returning 302 instead of 500.

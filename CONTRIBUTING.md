# Contributing

This repo provisions real Azure infrastructure via bash + `az` CLI. There is no mocked test suite —
"tested" means validated end-to-end against a live Azure deployment. Keep that bar for any change
you propose.

## Before you open a PR

- **State what you validated.** Ran `deploy-wg-gateway` against a live subscription? Only read the
  code? Say so in the PR description. Untested changes are welcome as drafts, but label them as such.
- **Don't hand-edit `yamls/generated/`.** Those files are generated (gitignored) from
  `yamls/templates/*.yaml.tpl` via `yamls/generate-*.sh`. Change the template and generator instead.
- **Keep "1 YAML = 1 container = 1 IP".** Each container is its own `az container create`, not
  grouped with others — this is a deliberate decision (see CLAUDE.md), not an oversight.
- **Writes to `vm-wg-gateway` must be sequential.** `az vm run-command invoke` against a single VM
  is effectively single-threaded; concurrent invocations race or corrupt shared state
  (`wg0.conf`, the DNS zone). Any new function that writes to the gateway joins an existing
  sequential step in `add-team-range` or gets its own — never runs inside the parallel step.

## Scope

- `docs/plans/*.md` marked "diseño" / "not implemented" are proposals, not documentation of
  running behavior. If you implement one, validate it against real Azure before updating its
  status.
- Secrets (`yamls/.env.secrets`) are never committed. If your change adds a new secret, add the
  placeholder to `yamls/.env.secrets.example` too.

## Reporting bugs / proposing features

Open a GitHub issue with: which command you ran, what you expected, what happened (include
`az` error output if relevant). For security issues, see `SECURITY.md` instead of opening a
public issue.

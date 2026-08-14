#!/usr/bin/env bash
#
# generate-monitor.sh — builds yamls/generated/monitor/, the complete tree that lab-azure.sh
# packages and pushes to vm-monitor (docker-compose + prometheus + blackbox + grafana + the
# discovery script). See docs/plans/observability-monitoring.md (F1).
#
# Templates resolved via envsubst (monitor-compose.yml.tpl, monitor-gen-targets.service.tpl);
# the rest of yamls/monitor/ (prometheus.yml, blackbox.yml, grafana/, remote/gen_targets.py,
# remote/gen-targets.timer) does not depend on any variables and is copied as-is — same spirit
# as generate-wiki-vm.sh.
#
# Environment variables used: RESOURCE_GROUP, GRAFANA_ADMIN_PASSWORD (literal if not exported,
# same as wiki secrets -- see yamls/README.md).
#
# Usage:
#   ./generate-monitor.sh
#
# Writes yamls/generated/monitor/

set -euo pipefail

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] missing 'envsubst' (package gettext-base)."; exit 1; }

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES="${WORKDIR}/templates"
SRC="${WORKDIR}/monitor"
OUTDIR="${WORKDIR}/generated/monitor"

export RESOURCE_GROUP="${RESOURCE_GROUP:-rg-ctf-semana-ingenieria-test}"
export GRAFANA_ADMIN_PASSWORD="${GRAFANA_ADMIN_PASSWORD:-sabanacorp-monitor-2026}"

rm -rf "$OUTDIR"
mkdir -p "$OUTDIR"

envsubst '${GRAFANA_ADMIN_PASSWORD}' < "${TEMPLATES}/monitor-compose.yml.tpl" > "${OUTDIR}/docker-compose.yml"
envsubst '${RESOURCE_GROUP}' < "${TEMPLATES}/monitor-gen-targets.service.tpl" > "${OUTDIR}/gen-targets.service"

cp -r "${SRC}/prometheus" "${SRC}/blackbox" "${SRC}/grafana" "${OUTDIR}/"
mkdir -p "${OUTDIR}/remote"
cp "${SRC}/remote/gen_targets.py" "${SRC}/remote/gen-targets.timer" "${OUTDIR}/remote/"

echo "generated: ${OUTDIR}"

#!/usr/bin/env bash
#
# generate-monitor.sh — arma yamls/generated/monitor/, el arbol completo que lab-azure.sh
# empaqueta y empuja a vm-monitor (docker-compose + prometheus + blackbox + grafana + el script
# de descubrimiento). Ver docs/plans/observability-monitoring.md (F1).
#
# Plantillas resueltas via envsubst (monitor-compose.yml.tpl, monitor-gen-targets.service.tpl);
# el resto de yamls/monitor/ (prometheus.yml, blackbox.yml, grafana/, remote/gen_targets.py,
# remote/gen-targets.timer) no depende de ninguna variable y se copia tal cual — mismo espiritu
# que generate-wiki-vm.sh.
#
# Variables de entorno usadas: RESOURCE_GROUP, GRAFANA_ADMIN_PASSWORD (literal si no se exporta,
# igual que los secretos del wiki -- ver yamls/README.md).
#
# Uso:
#   ./generate-monitor.sh
#
# Escribe yamls/generated/monitor/

set -euo pipefail

command -v envsubst >/dev/null 2>&1 || { echo "[ERROR] falta 'envsubst' (paquete gettext-base)."; exit 1; }

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

echo "generado: ${OUTDIR}"

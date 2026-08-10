#!/usr/bin/env bash
#
# apply-dns.sh.tpl -- plantilla envsubst, mismo patron que add-peer.sh.tpl: lab-azure.sh la
# resuelve LOCALMENTE (solo ${ZONE_NAME}/${ZONE_B64}, lista blanca explicita) y el resultado
# completo se manda como un unico string a 'az vm run-command invoke --scripts'.
#
# Instala un bloque de la zona DNS del lab en /etc/dnsmasq.hosts.d/${ZONE_NAME}. dnsmasq lo
# recarga solo (inotify via hostsdir), sin SIGHUP ni restart. Idempotente por construccion:
# reemplaza el archivo completo, nunca lo edita in-place.
#
# Ver docs/plans/internal-dns.md "Mecanismo de escritura de la zona y paralelismo".
set -euo pipefail

TMP="$(mktemp /tmp/lab.hosts.XXXXXX)"
trap 'rm -f "$TMP"' EXIT

echo "${ZONE_B64}" | base64 -d > "$TMP"

# Validacion minima antes de instalar: un archivo corrupto no debe llegar a hostsdir. No vacio y
# cada linea no vacia/no comentario empieza por una IP.
if [[ ! -s "$TMP" ]]; then
  echo "[ERROR] zona '${ZONE_NAME}' vino vacia, no se instala." >&2
  exit 1
fi
if grep -vE '^\s*(#.*)?$' "$TMP" | grep -vqE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]'; then
  echo "[ERROR] zona '${ZONE_NAME}' tiene lineas que no empiezan por IP, no se instala." >&2
  exit 1
fi

mkdir -p /etc/dnsmasq.hosts.d
# Instalacion atomica: install/mv desde /tmp, nunca 'cat >' directo sobre el destino -- inotify no
# debe ver nunca un archivo a medias.
install -m 644 "$TMP" "/etc/dnsmasq.hosts.d/${ZONE_NAME}"

# Espera corta + comprobacion de que dnsmasq responde. Si no, restart como red de seguridad.
sleep 1
PROBE="$(head -n1 "/etc/dnsmasq.hosts.d/${ZONE_NAME}" | awk '{print $2}')"
if [[ -n "$PROBE" ]] && ! dig +short @127.0.0.1 "$PROBE" >/dev/null 2>&1; then
  systemctl restart dnsmasq
  sleep 2
fi

N="$(grep -vcE '^\s*(#.*)?$' "/etc/dnsmasq.hosts.d/${ZONE_NAME}" || true)"
echo "OK registros=${N} zona=${ZONE_NAME}"

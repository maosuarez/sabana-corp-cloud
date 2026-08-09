#!/usr/bin/env bash
#
# add-peer.sh.tpl -- plantilla envsubst. NO se sube a la VM tal cual: lab-azure.sh la resuelve
# LOCALMENTE con 'envsubst' (solo ${PEER_NAME}/${TUNNEL_IP}/${ALLOWED_CIDRS} -- lista blanca
# explicita, igual que yamls/generate-team.sh, para no arriesgar que envsubst toque alguna otra
# '${...}' del script) y el resultado completo se manda como un unico string a
# 'az vm run-command invoke --scripts'. Por eso el script no recibe estos tres valores como
# variables de entorno remotas -- ya vienen horneados como texto literal cuando esto se ejecuta.
#
# Idempotente: si ya existe el keypair de este peer lo reusa (no invalida un .conf ya entregado).
# Seguro de correr de nuevo (VM recreada, add-team repetido): guard antes de duplicar en
# wg0.conf, iptables -C antes de -A.
set -euo pipefail
umask 077

KEYDIR="/etc/wireguard/peers"
mkdir -p "$KEYDIR"

if [[ ! -s "${KEYDIR}/${PEER_NAME}.key" ]]; then
  wg genkey | tee "${KEYDIR}/${PEER_NAME}.key" | wg pubkey > "${KEYDIR}/${PEER_NAME}.pub"
fi
PRIVKEY="$(cat "${KEYDIR}/${PEER_NAME}.key")"
PUBKEY="$(cat "${KEYDIR}/${PEER_NAME}.pub")"

# 1) Aplica en caliente -- wg set es idempotente, re-agregar el mismo peer no es un error.
wg set wg0 peer "$PUBKEY" allowed-ips "${TUNNEL_IP}"

# 2) Persiste en wg0.conf para que sobreviva un reboot (wg set por si solo es solo en memoria).
if ! grep -q "^# PEER:${PEER_NAME}\$" /etc/wireguard/wg0.conf; then
  cat >> /etc/wireguard/wg0.conf <<EOF

# PEER:${PEER_NAME}
[Peer]
PublicKey = ${PUBKEY}
AllowedIPs = ${TUNNEL_IP}
EOF
fi

# 3) Regla de FORWARD por cada CIDR permitido para este peer -- este es el control de acceso real
# (el AllowedIPs de arriba solo es crypto-key routing del lado servidor, no autoriza destino).
for cidr in ${ALLOWED_CIDRS}; do
  iptables -C FORWARD -s "${TUNNEL_IP}" -d "$cidr" -j ACCEPT 2>/dev/null || \
    iptables -A FORWARD -s "${TUNNEL_IP}" -d "$cidr" -j ACCEPT
done
netfilter-persistent save

# Salida parseable: una linea KEY=VALUE por dato, nada mas en stdout.
echo "PRIVKEY=${PRIVKEY}"
echo "PUBKEY=${PUBKEY}"
echo "TUNNEL_IP=${TUNNEL_IP}"

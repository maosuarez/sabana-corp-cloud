#!/usr/bin/env bash
#
# init-server-keys.sh -- idempotent, designed to run via 'az vm run-command invoke' against
# vm-wg-gateway. The real keypair is generated on first boot (yamls/wg-gateway/cloud-init.yaml,
# runcmd) because wg-quick needs PrivateKey defined to bring up wg0. This script exists
# for the case of requesting the server PUBKEY again later (create_wg_peer in lab-azure.sh runs it
# again instead of caching the value locally) and as a safety net if someday
# the keypair needs to be regenerated manually on a VM that already started without it (edge case, should not
# happen in normal flow).
set -euo pipefail
umask 077
mkdir -p /etc/wireguard

if [[ ! -s /etc/wireguard/server_private.key ]]; then
  wg genkey | tee /etc/wireguard/server_private.key | wg pubkey > /etc/wireguard/server_public.key
fi

if ! grep -q '^PrivateKey' /etc/wireguard/wg0.conf; then
  sed -i "/^\[Interface\]/a PrivateKey = $(cat /etc/wireguard/server_private.key)" /etc/wireguard/wg0.conf
  systemctl restart wg-quick@wg0
fi

echo "PUBKEY=$(cat /etc/wireguard/server_public.key)"

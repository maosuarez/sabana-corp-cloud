#!/usr/bin/env bash
#
# init-server-keys.sh -- idempotente, pensado para correr via 'az vm run-command invoke' contra
# vm-wg-gateway. El keypair real se genera en el primer boot (yamls/wg-gateway/cloud-init.yaml,
# runcmd) porque wg-quick necesita PrivateKey definido para poder levantar wg0. Este script existe
# para el caso de volver a pedir el PUBKEY del servidor despues (create_wg_peer en lab-azure.sh lo
# corre de nuevo en vez de cachear el valor localmente) y como red de seguridad si algun dia se
# necesita regenerar el keypair a mano en una VM que ya arranco sin el (edge case, no deberia
# pasar en el flujo normal).
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

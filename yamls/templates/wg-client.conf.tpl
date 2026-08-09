# Cliente WireGuard: ${PEER_NAME}
# Generado por yamls/generate-wg-client.sh -- no editar a mano, se regenera.
#
# El AllowedIPs de abajo (lado cliente) solo controla que trafico tu propio equipo enruta hacia
# el tunel -- NO es el mecanismo de seguridad. El control de acceso real (que subredes puede
# efectivamente alcanzar este peer) esta aplicado del lado del gateway via iptables, segun las
# reglas creadas para este peer en el momento en que se genero este archivo.
[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${CLIENT_TUNNEL_IP}
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUBKEY}
Endpoint = ${GATEWAY_PUBLIC_IP}:51820
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25

# Cliente WireGuard: ${PEER_NAME}
# Generado por yamls/generate-wg-client.sh -- no editar a mano, se regenera.
# Ver tambien ${PEER_NAME}-README.md en esta misma carpeta (guia de uso + nombres del lab).
#
# El AllowedIPs de abajo (lado cliente) solo controla que trafico tu propio equipo enruta hacia
# el tunel -- NO es el mecanismo de seguridad. El control de acceso real (que subredes puede
# efectivamente alcanzar este peer) esta aplicado del lado del gateway via iptables, segun las
# reglas creadas para este peer en el momento en que se genero este archivo. El unico /32 que no
# es un CIDR "de destino real" es el del DNS interno del lab (10.200.0.1) -- esta en AllowedIPs
# porque sin el, el propio driver de WireGuard descarta los paquetes DNS del cliente ANTES de
# mandarlos, no porque el gateway vaya a dejar pasar mas trafico hacia otro lado.
#
# DNS = <ip>, <dominio>: split-DNS real en Windows/macOS (app oficial) via NRPT/match-domains --
# solo lo que termina en el dominio del lab va al gateway, el resto sigue por tu DNS normal. En
# Linux (wg-quick + resolvconf/systemd-resolved) NO es split-DNS real: el dominio se toma como
# search domain y, segun el shim, buena parte del trafico DNS puede pasar por el gateway mientras
# el tunel esta arriba -- por eso dnsmasq reenvia a internet, para que no pierdas resolucion.
# Ver docs/plans/internal-dns.md "Cliente WireGuard y split-DNS por sistema operativo" para el
# detalle completo (incluye la trampa de 'nslookup' en Windows y el fix de 'resolvconf' en WSL2).
[Interface]
PrivateKey = ${CLIENT_PRIVKEY}
Address = ${CLIENT_TUNNEL_IP}
DNS = ${CLIENT_DNS}

[Peer]
PublicKey = ${SERVER_PUBKEY}
Endpoint = ${GATEWAY_PUBLIC_IP}:51820
AllowedIPs = ${CLIENT_ALLOWED_IPS}
PersistentKeepalive = 25

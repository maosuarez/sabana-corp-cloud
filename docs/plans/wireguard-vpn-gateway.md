# Plan: gateway WireGuard como entrada única al laboratorio

## Estado

**Validado end-to-end 2026-08-08.** `deploy-wg-gateway` corrido con éxito (`vm-wg-gateway`,
IP pública, `wg0` activo, keypair generado en boot). Peer admin y dos peers de equipo
(`team1`, `team2`, uno via `add-team 2` automático y otro via el nuevo subcomando
`wg-team-peer` para el caso de un equipo creado antes de que existiera el gateway) probados
desde un cliente WireGuard real (WSL2 + `wireguard-tools`, navegador Chromium vía WSLg):

- Admin conectado con `admin.conf` → `curl`/navegador a `dmz-filesrv` (10.50.0.6:8080) y al
  edificio de team1 → **200/OK** en ambos.
- `team1.conf` → propio edificio (`10.60.1.5:80`) → **302** (OK). `dmz-filesrv` → **200**
  (OK, contador iptables lo confirma).
- **Aislamiento equipo↔equipo confirmado con un ataque real**, no solo con la config por
  default: se editó a mano el `AllowedIPs` de `team1.conf` para incluir `10.60.2.0/24`
  (simulando un equipo que modifica su propio archivo para intentar alcanzar a otro) y se
  reconectó el túnel — el paquete sí salió esta vez (WireGuard ya no lo bloqueaba en el
  propio cliente), pero el contador de la política `DROP` en `iptables -L FORWARD -v -n`
  del gateway subió exactamente en los reintentos de `curl` (10 → 15 paquetes) mientras el
  `curl` local daba timeout — la capa de seguridad real (el gateway, no el cliente)
  bloqueó el intento tal como estaba diseñado. Ver "Bug encontrado y corregido" abajo para
  el detalle de un problema real que sí apareció en el camino.

Un hallazgo adicional no anticipado en el diseño original: **el `AllowedIPs` del lado
*cliente* en la definición del peer servidor (no las rutas de `ip route`) es en sí mismo
una capa de filtrado en el driver de WireGuard** — un intento de forzar una ruta del SO
hacia una subred no incluida en ese `AllowedIPs` (`ip route add ... dev <iface>`) es
rechazado instantáneamente por el propio kernel de WireGuard antes de salir a la red, sin
que el paquete llegue nunca al gateway. Solo editando el `AllowedIPs` real del `.conf` se
prueba el control de acceso real (el iptables del gateway). Útil saberlo para cualquier
prueba futura de este tipo — un `ip route add` a secas no basta para simular un intento de
bypass.

## Motivación

Hasta ahora el lab se opera entrando directo con `az` a cualquier subred — no hay una "entrada"
real, y nada le impide a un equipo alcanzar la subred de otro equipo o `snet-mgmt`. `CLAUDE.md` y
`docs/plans/network-segmentation-nsgs.md` ya dejaban anotado que el conector VPN estaba
"pendiente, sin diseño aún" y que la fila/columna `snet-wg-gateway` de la matriz NSG de ese
documento quedaba en blanco "hasta que exista un plan de VPN". Este documento es ese plan.

Requisitos que resuelve:
1. Una VM WireGuard en `snet-wg-gateway` (10.10.0.0/28, creada por `up`, vacía hasta ahora) como
   único punto de entrada al lab, alcanzable desde internet.
2. `add-team <N>` genera automáticamente un túnel nuevo para ese equipo, con acceso *solo* a su
   propia red (`snet-team<N>`) + la DMZ (el objetivo real del CTF) — nunca a otro equipo ni a
   `snet-mgmt`.
3. Un túnel admin, separado, con acceso a todo (`10.0.0.0/8`).
4. Un `.conf` de WireGuard generado automáticamente por cada túnel creado, listo para entregar.

## Por qué no son NSGs

`docs/plans/network-segmentation-nsgs.md` diseña una matriz de acceso por-subred (equipo↔equipo,
equipo→DMZ, nadie→mgmt). Eso sigue aplicando sin cambios al tráfico *dentro* de la VNet que no
pasa por el gateway. Pero el control que pide este plan es más fino: por-peer-de-túnel, no
por-subred (dos equipos comparten la misma "clase" de subred `snet-team<N>` pero deben tener
acceso mutuamente exclusivo — un NSG no puede expresar eso sin una regla por equipo que además
tendría que sincronizarse con el ciclo de vida de `add-team`, duplicando lo que ya hace
`add_team_subnet`). En vez de eso, el control de acceso vive **en la propia VM gateway**, vía
`iptables`:

- El `AllowedIPs` del lado servidor de WireGuard (`wg set wg0 peer ... allowed-ips ...`) solo hace
  *crypto-key routing* — define de qué IP de túnel se aceptan paquetes de ese peer. No dice nada
  sobre qué puede alcanzar del otro lado.
- El límite real de destino lo pone una regla `iptables -A FORWARD -s <ip_de_tunel_del_peer> -d
  <cidr_permitido> -j ACCEPT`, una por CIDR permitido, con `iptables -P FORWARD DROP` como default
  al final. Esto se agrega una vez por peer, en el momento en que se crea (`add-peer.sh.tpl`).

## Direccionamiento

- Overlay WireGuard `10.200.0.0/16` — existe solo dentro de la interfaz `wg0` del gateway, nunca
  se registra como subred de Azure (sin tocar route tables/UDR). El tráfico que sale de `wg0`
  hacia la VNet se enmascara (`iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE`), así que los
  servicios de equipo ven el tráfico como si viniera de la IP del propio gateway en
  `snet-wg-gateway` — no hace falta que Azure sepa nada de `10.200.0.0/16`.
- `wg0` del gateway: `10.200.0.1/16`.
- Peer admin: `10.200.0.2/32`, destino permitido `10.0.0.0/8` (todo).
- Peer `team<N>`: `10.200.<N>.2/32` (mismo número que `snet-team<N>`), destino permitido
  `10.60.<N>.0/24` + `10.50.0.0/24` + `10.51.0.0/24` (ambas DMZ).

## Piezas implementadas

- `yamls/wg-gateway/cloud-init.yaml` — boot de `vm-wg-gateway`: instala `wireguard`,
  `wireguard-tools`, `iptables-persistent`, `qrencode`; habilita `ip_forward`; genera el keypair
  del servidor *en el propio boot* (necesario porque `wg-quick` exige `PrivateKey` definido para
  poder levantar `wg0` — no se puede diferir a un paso posterior sin que el primer arranque
  falle); deja `wg0` con `PostUp`/`PostDown` (MASQUERADE + `FORWARD DROP`) pero **sin peers**.
- `yamls/wg-gateway/remote/init-server-keys.sh` — idempotente, corrido vía `run-command` cuando
  hace falta re-consultar la pubkey del servidor (no cachea nada localmente a propósito, ver
  abajo).
- `yamls/wg-gateway/remote/add-peer.sh.tpl` — plantilla `envsubst` (`${PEER_NAME}`,
  `${TUNNEL_IP}`, `${ALLOWED_CIDRS}`), resuelta **localmente** antes de mandarse completa como un
  solo string a `az vm run-command invoke` (mismo patrón que el one-liner base64 ya probado en
  `create_wiki_vm`). Idempotente: reusa keypair si ya existe, no duplica el `[Peer]` en
  `wg0.conf` (guard `# PEER:<name>`), `iptables -C` antes de `-A`.
- `yamls/templates/wg-client.conf.tpl` + `yamls/generate-wg-client.sh` — generan
  `yamls/generated/wg-clients/<name>.conf` (gitignored, contiene la private key del peer).
- `lab-azure.sh`: `create_wg_nsg`, `deploy_wg_gateway`, `create_wg_peer`, `create_wg_team_peer`
  (esta última llamada desde el final de `deploy_team()`, **guardada y no bloqueante**: si
  `vm-wg-gateway` no existe, `add-team` sigue funcionando igual — solo advierte que ese equipo
  queda sin túnel hasta correr `deploy-wg-gateway` y repetir). Nueva sección "Gateway WireGuard"
  en `status()`. Nuevo subcomando `deploy-wg-gateway`.
- **Deliberadamente no incluido en `test_deploy()`** (`./lab-azure.sh test [N]`) — sigue siendo el
  smoke test rápido de infra sin VPN; nada del núcleo del CTF depende de la VPN para que un
  equipo ya sea desplegable/atacable dentro de la VNet.

## Bug encontrado y corregido (primera corrida real)

Faltaba una regla `iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT` en el
`PostUp` de `wg0.conf`. Sin ella, las reglas por-peer (`-s <tunnel_ip> -d <cidr> -j ACCEPT`)
solo cubren la ida (cliente → destino); la respuesta llega ya des-enmascarada por conntrack
(origen = IP real del destino, ej. `10.50.0.6`, no la IP de túnel del cliente) y no matchea
ninguna regla — cae en el `DROP` por defecto. Síntoma observado: handshake de WireGuard
exitoso, pero cualquier conexión TCP se caía después del primer paquete (`curl` con timeout,
contador de `DROP` subiendo mientras el de `ACCEPT` del peer quedaba estancado). Corregido en
caliente en `vm-wg-gateway` (regla insertada + `netfilter-persistent save`), en su
`/etc/wireguard/wg0.conf` (para que sobreviva un reboot) y en
`yamls/wg-gateway/cloud-init.yaml` (para que los próximos gateways no repitan el bug).

También se agregó el subcomando `./lab-azure.sh wg-team-peer <N>` — necesario porque `team1`
se había desplegado antes de que existiera el gateway (el guard no-bloqueante de
`create_wg_team_peer` se activó en ese momento) y no había forma de generar su túnel
retroactivamente sin repetir todo `add-team`.

## Riesgos ya confirmados resueltos en la primera corrida

1. ~~Forma de invocar `run-command` para `add-peer.sh`~~ — funcionó tal cual estaba diseñado
   (script completo multilínea como un solo `--scripts`), sin ajustes.
2. ~~Interfaz de red asumida como `eth0`~~ — confirmado correcto en esta imagen (`Ubuntu2204`).
3. ~~`iptables-persistent` con debconf no-interactivo~~ — instaló sin colgarse.
4. ~~Pruebas negativas de aislamiento equipo↔equipo~~ — validadas con un intento real de bypass
   (ver arriba), incluyendo el hallazgo del bug de `RELATED,ESTABLISHED` que sin esta prueba
   habría pasado desapercibido.

## Riesgos que siguen abiertos

1. La private key de cada peer se genera en la VM y viaja de vuelta por el canal de salida de
   `az vm run-command invoke` (cifrado TLS, pero logueado en Azure Activity Log) en vez de
   generarse localmente y no salir nunca de la VM. Decisión consciente para no depender de tener
   `wireguard-tools` instalado en la máquina del operador — trade-off, no descuido.
2. No probado: aislamiento hacia `snet-mgmt` (sigue vacía, sin servicios) ni comportamiento tras
   un reboot real de `vm-wg-gateway` (la persistencia en `wg0.conf`/`netfilter-persistent` está
   escrita pero nunca se forzó un reinicio para confirmarla).

## Verificación (primera corrida real, en orden)

```bash
# 1. wg0 activo tras el boot
az vm run-command invoke -g rg-ctf-semana-ingenieria-test -n vm-wg-gateway --command-id RunShellScript \
  --scripts "systemctl is-active wg-quick@wg0 && wg show wg0" \
  --query "value[0].message" -o tsv | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}'

# 2. Esqueleto iptables correcto (DROP + MASQUERADE) antes de cualquier peer
az vm run-command invoke -g rg-ctf-semana-ingenieria-test -n vm-wg-gateway --command-id RunShellScript \
  --scripts "iptables -L FORWARD -v -n; echo ---; iptables -t nat -L POSTROUTING -v -n" \
  --query "value[0].message" -o tsv | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}'

# 3. deploy-wg-gateway crea el peer admin server-side
./lab-azure.sh deploy-wg-gateway
az vm run-command invoke -g rg-ctf-semana-ingenieria-test -n vm-wg-gateway --command-id RunShellScript \
  --scripts "wg show wg0 peers" --query "value[0].message" -o tsv \
  | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}'

# 4. Extremo a extremo desde la máquina del operador con admin.conf (requiere wireguard-tools local)
sudo wg-quick up ./yamls/generated/wg-clients/admin.conf
curl -s http://<ip-de-dmz-filesrv>:8080/     # debe funcionar (admin llega a todo)
sudo wg-quick down ./yamls/generated/wg-clients/admin.conf

# 5. add-team 2 (para tener dos equipos) y probar aislamiento con team1.conf -- EL TEST CLAVE
./lab-azure.sh add-team 2
sudo wg-quick up ./yamls/generated/wg-clients/team1.conf
curl -s http://<team1-webapp-ip>:PORT/                 # debe funcionar (su propia red)
curl -s http://<ip-de-dmz-filesrv>:8080/                # debe funcionar (DMZ permitida)
curl -s --max-time 5 http://<team2-webapp-ip>:PORT/     # debe FALLAR/timeout (bloqueado)
sudo wg-quick down ./yamls/generated/wg-clients/team1.conf
```

## Abierto / no decidido

- Un solo peer admin por ahora (no un sistema multi-admin) — suficiente para el operador único
  actual, ampliable después si hace falta.
- No hay comando de revocación/remoción de peer — no se pidió, y el ciclo de vida del lab hoy es
  "todo se destruye con `down`", no remoción selectiva.
- Costo: la VM del gateway (con IP pública) queda encendida indefinidamente salvo apagado manual
  (`az vm deallocate`) — igual que `vm-wiki`, decidir si se apaga fuera de ventanas de prueba.
- `wg show wg0` no etiqueta peers por nombre (solo por pubkey) — aceptable para una primera
  versión; una tabla más legible necesitaría cruzar contra los comentarios `# PEER:<name>` de
  `wg0.conf`, no implementado todavía.

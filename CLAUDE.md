# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es esto

Infraestructura como código para **Sabana Corp**, el CTF de la Semana de Ingeniería de la
Universidad de la Sabana. Todo corre en Azure Container Instances (ACI) dentro de una VNet
sin salida a internet — se llega tras romper un portal cautivo y autenticarse por VPN.

Estado actual: `lab-azure.sh` levanta la infraestructura base (RG, VNet, subredes) y orquesta el
despliegue de la DMZ compartida, la VM del wiki, el gateway WireGuard y N equipos usando los YAML
de `yamls/`.

**Todo lo implementado se probó end-to-end el 2026-08-08**: `up`, `deploy-dmz`, `deploy-wiki-vm`,
`deploy-wg-gateway`, `add-team`/`add-team-range` y el flujo VPN completo. Cuando un comentario del
código diga "validado 2026-08-08", se refiere a esa corrida. Lo que **no** está implementado ni
probado es: CTFd, Provisioner y Monitor (sin imagen en ningún repo todavía) y los planes de
`docs/plans/` marcados como diseño — `network-segmentation-nsgs.md`, `observability-monitoring.md`
e `internal-dns.md`. Este archivo se va actualizando a medida que se toman decisiones de diseño.

## Comandos

```bash
export DOCKERHUB_USER="..."
export DOCKERHUB_TOKEN="..."   # Docker Hub -> Account Settings -> Security -> New Access Token
cp yamls/.env.secrets.example yamls/.env.secrets   # solo la primera vez, editar flags/secretos reales

./lab-azure.sh up                # RG + VNet + subredes base + delega snet-dmz-shared a ACI
./lab-azure.sh deploy-dmz        # despliega los 13 contenedores compartidos de la DMZ (wiki aparte, ver abajo)
./lab-azure.sh deploy-wiki-vm    # crea vm-wiki (wiki+wiki-db via docker-compose) en snet-dmz-vm
./lab-azure.sh deploy-wg-gateway # crea vm-wg-gateway (WireGuard, IP pública) + túnel admin en snet-wg-gateway
./lab-azure.sh add-team 1        # crea snet-team1, despliega sus 4 contenedores y su túnel WireGuard
./lab-azure.sh add-team 2        # repetir por cada equipo adicional (mismo comando, distinto N)
./lab-azure.sh add-team-range 1 20   # despliega equipos 1..20 (secuencial, detiene en error)
./lab-azure.sh add-team-range 1 20 4 # idem pero 4 equipos en paralelo (subnets/peers WG secuenciales)
./lab-azure.sh wg-team-peer 1    # genera túnel WireGuard para team1 (para equipos desplegados antes del gateway)
./lab-azure.sh test [N]          # atajo de prueba: up + deploy-dmz + add-team N (N=1 por defecto, sin VPN)
./lab-azure.sh status            # estado de DMZ, DMZ-VM, gateway WireGuard y equipos
./lab-azure.sh down              # borra el Resource Group completo (pide confirmación "si")
```

Prerrequisitos: `az` CLI instalado y logueado (`az login`) contra la suscripción "Azure for
Students" del tenant de la Universidad de la Sabana; `envsubst` (paquete `gettext-base`) para
`yamls/generate-{team,dmz,wg-client}.sh`. Cliente WireGuard (paquete `wireguard-tools`) solo
necesario en el operador para usar los `.conf` generados — no es prerrequisto del script.

Diseño de `up`/`down`: todo el lab vive en un único Resource Group
(`rg-ctf-semana-ingenieria-test`), así que "down" es un solo comando que lo destruye entero.
Mantener este invariante al extender el script — no crear recursos fuera del RG del lab.

## Costos

```bash
az consumption usage list --output table   # consumo detallado
az billing account list -o table
az consumption budget list --output table
```

Suscripción es "Azure for Students" (crédito, no pay-as-you-go): `az consumption usage list`
suele devolver 403/AuthorizationFailed en este tipo de suscripción — no es un error de config, es
una limitación conocida de Azure for Students. En ese caso el balance de crédito solo se ve en el
portal: portal.azure.com → Suscripciones → Azure for Students → Cost analysis (o el widget de
crédito restante en el dashboard).

## Decisión de diseño: 1 YAML = 1 contenedor = 1 IP

Cada contenedor se despliega como su propio `az container create --file <container>.yaml`
(container group de un solo contenedor), no agrupado con otros — así cada uno recibe su propia
IP privada dentro de la subred de su equipo o de la DMZ, en vez de compartir una sola IP como
pasaba en el primer prototipo (`team1-edificio`, ya reemplazado).

## Decisión de diseño: xss-bot es N instancias (una por equipo), no 1 bot compartido

Se evaluó consolidar el `xss-bot` de todos los equipos en un único contenedor compartido (en
`snet-mgmt`, con acceso saliente a cada `snet-teamX` pero sin entrante desde ellas vía NSG) para
ahorrar RAM: hoy son N contenedores Playwright/Chromium, uno por equipo.

Se descartó. Motivo: en un CTF donde los equipos compiten explotando XSS contra el bot, el
aislamiento entre equipos es parte del modelo de amenaza, no solo un costo a optimizar. Un bot
compartido introduce:
- **Punto único de falla**: si un equipo tumba o cuelga el bot (payload `while(true)`, etc.), el
  Reto 1 se cae para todos los equipos simultáneamente, no solo para el atacante.
- **Superficie cruzada**: cualquier bug en el loop que visita las colas de N equipos arriesga
  filtrar cookies/timing de un equipo hacia otro.
- **Complejidad de red no validada**: requeriría NSGs para el aislamiento direccional
  (`snet-mgmt` → `snet-teamX` sí, `snet-teamX` → `snet-mgmt` no), algo que el proyecto aún no ha
  probado (ver nota de NSGs en "Arquitectura de red objetivo").

El ahorro de RAM no justifica esa complejidad de forma preventiva. Revisar esta decisión solo si
el costo real (medido, no estimado) se vuelve un problema — no antes.

## Decisión de diseño: plantillas + generadores, no YAML estático

Los YAML que dependen de un equipo o de secretos compartidos no se escriben a mano ni se
commitean resueltos: viven como plantillas en `yamls/templates/*.yaml.tpl` con variables
`${...}` (envsubst), y `yamls/generate-team.sh <N>` / `yamls/generate-dmz.sh` las resuelven en
`yamls/generated/*.yaml` (gitignored). `lab-azure.sh` (`add-team`, `deploy-dmz`) llama a estos
generadores y despliega su salida — no hay que tocar `yamls/` a mano en el flujo normal.

- **`templates/team-*.yaml.tpl`** (database, webapp, linux-server, xss-bot) — agnósticas al
  número de equipo vía `${TEAM}`; misma plantilla sirve para team1, team2, ..., teamN. Imágenes
  `maosuarez/sabana-lab-*:latest` (repo `../sabana-corp-network`), subred `snet-team${TEAM}`.
- **`templates/dmz-*.yaml.tpl`** (filesrv, parking, 11 decoy-*) — 13 contenedores, un solo
  despliegue compartido, no dependen de ningún equipo. Imágenes propias en Docker Hub
  `maosuarez` (`sabanacorp-filesrv`, `sabanacorp-parking`, `sabanacorp-decoy`), construidas a
  partir de `../sabana-corp-dmz` con el contenido del reto ya horneado. Subred fija
  `snet-dmz-shared`. El wiki no está en ACI (ver `deploy-wiki-vm`); sus plantillas
  `dmz-wiki*.yaml.tpl` fueron borradas porque se generaban sin desplegarse.

Las flags/secretos de los servicios por equipo (`FLAG_*`, `PIVOT_SSH_PASSWORD`, `BOT_SECRET`,
contraseñas de DB, `JWT_SIGNING_SECRET`) **son los mismos para todos los equipos** — vienen de
`yamls/.env.secrets` (gitignored, plantilla en `.env.secrets.example`), nunca de `${TEAM}`.
Decisión deliberada: CTFd valida una única flag por reto para cualquier equipo, así que cargarla
una vez en CTFd sirve para las N instancias. Los secretos de la DMZ (parking en su plantilla, y
los del wiki en `generate-wiki-vm.sh`) siguen como literales — la DMZ es un único despliegue, no
N copias.

ACI no da DNS entre container groups distintos, así que un contenedor que depende de la IP de
otro (`webapp`→`database`, `xss-bot`→`webapp`) no puede usar el nombre del servicio como en
docker-compose. `deploy_dmz`/`deploy_team` en `lab-azure.sh` resuelven esto automáticamente:
despliegan la dependencia primero, leen su IP con `az container show/create --query
ipAddress.ip`, y la inyectan con `sed` en el YAML generado del dependiente antes de desplegarlo.
(El wiki dejó de necesitar esta inyección al migrar de ACI a una VM con docker-compose, donde
la resolución de nombres entre servicios es nativa.) Ver `yamls/README.md` para el detalle de
ese orden si hay que depurarlo.

Hay un plan para montar DNS interno del lab (dnsmasq en `vm-wg-gateway`, FQDN para equipos y DMZ,
resolución también desde el PC del participante por el túnel WireGuard) en
`docs/plans/internal-dns.md` — **diseño, no implementado**, y pensado para ejecutarse *después* de
que la DMZ completa esté montada. Ojo: ese plan no elimina el `sed` de IPs de arriba (el orden de
despliegue lo sigue exigiendo), solo agrega nombres encima.

## Decisión de diseño: paralelismo en add-team-range

Desplegar un solo equipo (`add-team N`) es secuencial: subred → contenedores (con dependencias
db→webapp→xss-bot) → túnel WireGuard. La operación es lenta por el pool de IPs esperando en ACI
(~30s por 4 contenedores).

`add-team-range <inicio> <fin> [paralelismo]` permite desplegar múltiples equipos concurrentes:

- **Paso 1 (secuencial)**: crea todas las subredes de golpe (`add_team_subnet` para cada equipo).
  Motivo: `az network vnet subnet create` concurrentes sobre la MISMA VNet chocan frecuentemente
  con `409 AnotherOperationInProgress` — Azure no permite operaciones de subred paralelas en una
  VNet.
- **Paso 2 (paralelo, tope configurable)**: `deploy_team_workload` (generación YAML + deploy de
  contenedores) de N equipos simultáneos, con tope de concurrencia vía job control bash
  (`wait -n`). Este paso es lo lento: cada equipo espera sus 4 IPs (~30s), en paralelo los equipos
  se aceleran (4 equipos × 30s secuencial = 2 min; en paralelo ÷ tope de 4 ≈ 30s).
- **Paso 3 (secuencial)**: `create_wg_team_peer` por equipo para generar túneles WireGuard.
  Motivo: los peers usan `az vm run-command invoke` contra la misma VM (`vm-wg-gateway`), que
  ejecuta `add-peer.sh.tpl` de forma serial — correrlos en paralelo arriesga corromper la config
  compartida (`/etc/wireguard/wg0.conf`).

Ejemplo: `./lab-azure.sh add-team-range 1 20 4` crea 20 equipos con 4 en paralelo (vs. 20×
secuencial): subnets ~5s (paso 1), workloads ~2-3 min (paso 2 en paralelo), peers ~20s (paso 3),
total ~3 min vs. ~10 min secuencial.

## Arquitectura de red objetivo

**vnet-ctf-lab** (`10.0.0.0/8`) — red sin internet, alcanzable solo tras el portal cautivo +
VPN.

- **snet-dmz-shared** (`10.50.0.0/24`) — servicios compartidos por todos los equipos:
  - CTFd (flags y scoreboard) — no implementado todavía
  - Provisioner (FastAPI) — habla con la API de Azure/VPC para aprovisionar recursos de equipo — no implementado todavía
  - Objetivo de XSS contra un admin-bot — implementado como `filesrv`/`wiki`/`parking`/decoys (ver `yamls/templates/dmz-*.yaml.tpl`); el admin-bot en sí vive en `xss-bot` por equipo (`snet-teamN`), no en la DMZ
  - Monitor (Prometheus + Grafana) para el staff — no implementado todavía (hay un decoy que imita uno, `dmz-decoy-monitor`, no confundir)
- **snet-teamX** (`10.60.X.0/24`, una por equipo, `X` = número de equipo) — red propia de cada
  equipo, creada bajo demanda con `./lab-azure.sh add-team <X>`:
  - File-Srv — vulnerable a acceso anónimo, pivote hacia el siguiente nivel (vive en la DMZ compartida, no aquí — ver nota abajo)
  - Wiki-Int — pistas criptográficas (idem, DMZ compartida)
  - servicios decoy — simulan ruido corporativo (idem, DMZ compartida)
  - Parqueadero — reto final (idem, DMZ compartida)
  - Lo que sí vive en `snet-teamX`: `database`, `webapp`, `linux-server`, `xss-bot` (retos 1-3 del edificio de cada equipo)
- **snet-mgmt** (`10.99.0.0/24`) — red de gestión, creada por `up`, sin servicios todavía
- **snet-dmz-vm** (`10.51.0.0/24`) — DMZ paralela para servicios que no corren en ACI. Hoy aloja
  `vm-wiki` (wiki + wiki-db vía docker-compose), migrada de ACI porque BookStack requiere PID 1
  real (s6-overlay, limitación de ACI+VNet — validado end-to-end 2026-08-08). No puede ir en
  `snet-dmz-shared` porque esa subred está delegada a `Microsoft.ContainerInstance/containerGroups`
  (delegación exclusiva, no admite VMs). Ver `docs/plans/wiki-on-vm.md` para el detalle.
- **snet-wg-gateway** (`10.10.0.0/28`) — única entrada al lab: `vm-wg-gateway` (IP pública,
  WireGuard UDP 51820), creada por `./lab-azure.sh deploy-wg-gateway`. `add-team <N>` genera
  automáticamente el túnel de ese equipo (acceso solo a su propia `snet-teamN` + ambas DMZ) y un
  `.conf` en `yamls/generated/wg-clients/`; hay además un túnel admin con acceso a todo
  `10.0.0.0/8`. El control de acceso por túnel se aplica con `iptables` en la propia VM, no con
  NSGs (más detalle, validación end-to-end y estado de pruebas en `docs/plans/wireguard-vpn-gateway.md`,
  **validado end-to-end 2026-08-08**).

Nota de implementación vs. arquitectura original: File-Srv/Wiki-Int/decoys/Parqueadero se
describieron inicialmente como parte de la red de cada equipo, pero el repo `sabana-corp-dmz` los
implementó como un único despliegue compartido en `snet-dmz-shared` (ver
`../sabana-corp-dmz/README.md`). Se siguió esa implementación real en vez de la descripción
original — si se decide separarlos por equipo más adelante, hay que revisar esta sección.

Conector VPN: implementado y validado end-to-end 2026-08-08, ver `docs/plans/wireguard-vpn-gateway.md`.
Dentro de la VNet, el acceso entre subredes sigue siendo libre albedrío total (Azure enruta entre
subredes de la misma VNet por defecto, y no hay un solo NSG de segmentación creado sobre
`snet-team*`/`snet-dmz-*`/`snet-mgmt`) — un equipo puede alcanzar la subred de otro equipo, o
`snet-mgmt`, sin restricción, **si entra por fuera del gateway VPN** (ej. con acceso directo a `az`).
Propuesta de reglas para cerrar eso a nivel de subred (equipos aislados entre sí, nadie puede
llegar a `snet-mgmt` salvo staff, DMZ no puede iniciar conexiones hacia equipos) documentada en
`docs/plans/network-segmentation-nsgs.md` — **no implementada todavía**, solo diseño; es un
control complementario al del gateway VPN, no un prerrequisito.

## Notas de archivos

- `lab-azure.sh` — orquesta todo el ciclo de vida: infraestructura base (`up`), DMZ
  (`deploy-dmz`), equipos (`add-team <N>`, `add-team-range`), wiki-vm (`deploy-wiki-vm`), gateway
  VPN (`deploy-wg-gateway`), estado (`status`) y destrucción (`down`). Llama a los generadores de
  `yamls/` y resuelve las dependencias de IP entre contenedores. Implementa paralelismo configurable
  en `add-team-range` (subnets secuenciales, workloads paralelos, peers secuenciales).
- `.env` — `DOCKERHUB_USER` / `DOCKERHUB_TOKEN`; el script no lo carga automáticamente, hay que
  exportar las variables a mano antes de correr cualquier comando que despliegue contenedores.
- `yamls/` — plantillas, generadores y documentación del despliegue por contenedor. Incluye:
  - `templates/*.yaml.tpl` + `generate-*.sh` para DMZ/equipos/wiki-vm/clientes WireGuard
  - `wg-gateway/` — VM cloud-init, scripts remotos para gestión de peers del gateway
  - `generated/` (gitignored) — YAML resueltos y clientes WireGuard generados
  Ver `yamls/README.md` para el detalle.

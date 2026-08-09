# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Qué es esto

Infraestructura como código para **Sabana Corp**, el CTF de la Semana de Ingeniería de la
Universidad de la Sabana. Todo corre en Azure Container Instances (ACI) dentro de una VNet
sin salida a internet — se llega tras romper un portal cautivo y autenticarse por VPN.

Estado actual: `lab-azure.sh` levanta la infraestructura base (RG, VNet, subredes) y orquesta el
despliegue de la DMZ compartida y de N equipos usando los YAML de `yamls/`. La arquitectura
completa (abajo) todavía no está implementada en su totalidad (CTFd, Provisioner, Monitor, VPN
faltan) — este archivo se va actualizando a medida que se toman decisiones de diseño.

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
./lab-azure.sh test [N]          # atajo de prueba: up + deploy-dmz + add-team N (N=1 por defecto, sin VPN)
./lab-azure.sh status            # estado de DMZ, DMZ-VM, gateway WireGuard y equipos
./lab-azure.sh down              # borra el Resource Group completo (pide confirmación "si")
```

Prerrequisitos: `az` CLI instalado y logueado (`az login`) contra la suscripción "Azure for
Students" del tenant de la Universidad de la Sabana; `envsubst` (paquete `gettext-base`) para
`yamls/generate-{team,dmz}.sh`.

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
- **`templates/dmz-*.yaml.tpl`** (filesrv, wiki-db, wiki, parking, 11 decoy-*) — un solo
  despliegue compartido, no dependen de ningún equipo. Imágenes propias en Docker Hub
  `maosuarez` (`sabanacorp-filesrv`, `sabanacorp-wikidb`, `sabanacorp-parking`,
  `sabanacorp-decoy`), construidas a partir de `../sabana-corp-dmz` con el contenido del reto ya
  horneado — salvo `wiki`, que sigue en `lscr.io/linuxserver/bookstack` (imagen pública genérica).
  Subred fija `snet-dmz-shared`.

Las flags/secretos de los servicios por equipo (`FLAG_*`, `PIVOT_SSH_PASSWORD`, `BOT_SECRET`,
contraseñas de DB, `JWT_SIGNING_SECRET`) **son los mismos para todos los equipos** — vienen de
`yamls/.env.secrets` (gitignored, plantilla en `.env.secrets.example`), nunca de `${TEAM}`.
Decisión deliberada: CTFd valida una única flag por reto para cualquier equipo, así que cargarla
una vez en CTFd sirve para las N instancias. Los secretos de la DMZ (wiki-db, parking) siguen
como literales en su plantilla — la DMZ es un único despliegue, no N copias.

ACI no da DNS entre container groups distintos, así que un contenedor que depende de la IP de
otro (`webapp`→`database`, `xss-bot`→`webapp`, `wiki`→`wiki-db`) no puede usar el nombre del
servicio como en docker-compose. `deploy_dmz`/`deploy_team` en `lab-azure.sh` resuelven esto
automáticamente: despliegan la dependencia primero, leen su IP con `az container show/create
--query ipAddress.ip`, y la inyectan con `sed` en el YAML generado del dependiente antes de
desplegarlo. Ver `yamls/README.md` para el detalle de ese orden si hay que depurarlo.

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
- **snet-dmz-vm** (`10.51.0.0/24`) — DMZ paralela para servicios que no corren en ACI (creada por
  `up`, sin delegar, sin servicios todavía). Ver `docs/plans/wiki-on-vm.md`: `dmz-wiki` no arranca
  en ACI (s6-overlay exige PID 1, ACI+VNet no lo garantiza) — migra aquí vía VM + docker-compose
  el día que haya cuota de VM. No puede ir en `snet-dmz-shared` porque esa subred está delegada a
  `Microsoft.ContainerInstance/containerGroups` (delegación exclusiva, no admite VMs).
- **snet-wg-gateway** (`10.10.0.0/28`) — única entrada al lab: `vm-wg-gateway` (IP pública,
  WireGuard UDP 51820), creada por `./lab-azure.sh deploy-wg-gateway`. `add-team <N>` genera
  automáticamente el túnel de ese equipo (acceso solo a su propia `snet-teamN` + ambas DMZ) y un
  `.conf` en `yamls/generated/wg-clients/`; hay además un túnel admin con acceso a todo
  `10.0.0.0/8`. El control de acceso por túnel se aplica con `iptables` en la propia VM, no con
  NSGs (más detalle y estado de pruebas en `docs/plans/wireguard-vpn-gateway.md`, **NO PROBADO
  todavía**).

Nota de implementación vs. arquitectura original: File-Srv/Wiki-Int/decoys/Parqueadero se
describieron inicialmente como parte de la red de cada equipo, pero el repo `sabana-corp-dmz` los
implementó como un único despliegue compartido en `snet-dmz-shared` (ver
`../sabana-corp-dmz/README.md`). Se siguió esa implementación real en vez de la descripción
original — si se decide separarlos por equipo más adelante, hay que revisar esta sección.

Conector VPN: en diseño/implementación, ver `docs/plans/wireguard-vpn-gateway.md` (NO PROBADO
todavía contra Azure real). Dentro de la VNet, el acceso entre subredes sigue siendo libre
albedrío total (Azure enruta entre subredes de la misma VNet por defecto, y no hay un solo NSG de
segmentación creado sobre `snet-team*`/`snet-dmz-*`/`snet-mgmt`) — un equipo puede alcanzar la
subred de otro equipo, o `snet-mgmt`, sin restricción, **si entra por fuera del gateway VPN**
(ej. con acceso directo a `az`). Propuesta de reglas para cerrar eso a nivel de subred (equipos
aislados entre sí, nadie puede llegar a `snet-mgmt` salvo staff, DMZ no puede iniciar conexiones
hacia equipos) documentada en `docs/plans/network-segmentation-nsgs.md` — **no implementada
todavía**, solo diseño; es un control complementario al del gateway VPN, no un prerrequisito.

## Notas de archivos

- `lab-azure.sh` — orquesta todo el ciclo de vida: infraestructura base (`up`), DMZ
  (`deploy-dmz`), equipos (`add-team <N>`), estado (`status`) y destrucción (`down`). Llama a los
  generadores de `yamls/` y resuelve las dependencias de IP entre contenedores.
- `.env` — `DOCKERHUB_USER` / `DOCKERHUB_TOKEN`; el script no lo carga automáticamente, hay que
  exportar las variables a mano antes de correr cualquier comando que despliegue contenedores.
- `yamls/` — plantillas, generadores y documentación del despliegue por contenedor (ver
  `yamls/README.md` para el detalle).

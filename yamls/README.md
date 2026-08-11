# yamls/

Un archivo ACI (`az container create --file <archivo>.yaml`) por contenedor. Cada uno recibe su
propia IP privada al desplegarse — así es como se logra "todos IPs diferentes" en vez de agrupar
varios contenedores en un solo container group (que comparten una sola IP).

Uso normal: no se corre nada de esta carpeta a mano. `../lab-azure.sh` (`deploy-dmz`, `add-team
<N>`) orquesta generación + despliegue + resolución de IPs entre contenedores dependientes. Esta
carpeta documenta cómo funciona esa orquestación por si hay que depurarla o extenderla.

## Contenido

**`templates/team-*.yaml.tpl`** — plantillas agnósticas al número de equipo (variable `${TEAM}`),
una por servicio: `database`, `webapp`, `linux-server`, `xss-bot`. Imágenes de
`sabana-corp-network`, subred `snet-team${TEAM}`.

**`templates/dmz-*.yaml.tpl`** — plantillas de los servicios compartidos (no dependen de ningún
equipo): `filesrv`, `parking`, 11 `decoy-*` — 13 en total, todas desplegadas por `deploy-dmz`.
Las imágenes son de la cuenta Docker Hub `maosuarez` (`sabanacorp-filesrv`,
`sabanacorp-parking`, `sabanacorp-decoy`), construidas a partir del contenido de
`sabana-corp-dmz`. Subred fija `snet-dmz-shared`. **El wiki no está aquí**: `dmz-wiki.yaml.tpl` y
`dmz-wiki-db.yaml.tpl` existieron y fueron borradas (BookStack no arranca en ACI, y se generaban
sin desplegarse nunca) — hoy `wiki` + `wiki-db` corren en `vm-wiki`, ver
`wiki-vm-compose.yml.tpl` abajo.

**`generate-team.sh <N>`** / **`generate-dmz.sh`** — resuelven `${DOCKERHUB_USER}`,
`${DOCKERHUB_TOKEN}`, `${SUBSCRIPTION_ID}`, `${RESOURCE_GROUP}`, `${VNET}` (y `${TEAM}` en el caso
de team) sobre las plantillas correspondientes, escribiendo en `generated/`. `lab-azure.sh` los
llama con esas variables ya resueltas (`RG`, `VNET`, subscription id vía `az account show`); solo
hay que exportar `DOCKERHUB_USER`/`DOCKERHUB_TOKEN` y tener `.env.secrets` listo. Invocarlos a mano
solo hace falta para depurar la generación sin desplegar.

También resuelven `${LAB_DOMAIN}`/`${LAB_DNS_SERVER}` (ver "DNS interno" abajo) — si
`LAB_DNS_SERVER` viene vacío (lab sin `vm-wg-gateway` desplegado todavía, o `./lab-azure.sh test`),
el generador borra el bloque `dnsConfig` del YAML resultante con `sed` entre los centinelas
`DNSCONFIG-BEGIN`/`DNSCONFIG-END` — `envsubst` no soporta condicionales, así que esa es la forma
más simple de que el mismo template sirva con y sin gateway.

`generated/` está en `.gitignore` (contiene secretos resueltos) — es la salida intermedia que
`lab-azure.sh` despliega con `az container create --file`, no se versiona.

**`templates/wiki-vm-compose.yml.tpl`** / **`generate-wiki-vm.sh`** / **`wiki-vm/cloud-init.yaml`**
— Validado end-to-end 2026-08-08, ver `docs/plans/wiki-on-vm.md`. Generan/despliegan
(`lab-azure.sh deploy-wiki-vm`) un docker-compose de wiki+wiki-db sobre una VM en `snet-dmz-vm`,
en vez de ACI (workaround al problema de s6-overlay/PID1 documentado en la memoria del proyecto).
La resolución de nombres entre `wiki` y `wiki-db` funciona nativamente vía la red de Docker
`wiki_backend` del compose, sin necesidad de inyección de IP.

**`templates/ctfd-compose.yml.tpl`** / **`generate-ctfd-vm.sh`** / **`ctfd-vm/`** — F2 de
`docs/plans/ctfd-deployment.md`, **validado end-to-end contra Azure real (2026-08-11)**.
Mismo patrón que wiki (VM en `snet-dmz-vm`, `lab-azure.sh deploy-ctfd-vm`), stack completo
adaptado de `../sabana-corp-CTFd/docker-compose.prod.yml` (nginx + ctfd/gunicorn + MariaDB +
Redis). A diferencia del wiki, los secretos (`SECRET_KEY`, credenciales de DB, admin precreado)
sí vienen de `.env.secrets` (bloque `CTFD_*`) — decisión explícita del plan, ver
`generate-ctfd-vm.sh`. Imagen: `${DOCKERHUB_USER}/sabana-corp-ctfd`, publicada por
`../sabana-corp-CTFd/.github/workflows/deploy.yml`. Primer arranque sin clicks manuales:
`create_ctfd_vm()` corre `../sabana-corp-CTFd/scripts/seed_setup.py` (vendored en
`generated/ctfd/seed/`, ejecuta dentro del contenedor `ctfd` vía `docker compose exec`) para
completar el wizard de `/setup`, y `CTFD_PRESET_ADMIN_TOKEN` (`PRESET_ADMIN_TOKEN` nativo de CTFd)
reemplaza el Access Token que normalmente hay que generar a mano por la UI.

**`.env.secrets`** (gitignored, plantilla en `.env.secrets.example`) — flags y secretos de los
servicios **por equipo**, **compartidos por todos los equipos**: `add-team 1` y `add-team 2`
producen el mismo `FLAG_DATABASE`, `FLAG_WEBAPP_XSS`, etc. Solo cambia el nombre del container
group y la subred. Esto es intencional: CTFd valida una única flag por reto para todos los
equipos, así que cargarla una vez en CTFd sirve para cualquier instancia. Editar `.env.secrets` y
volver a correr `add-team <N>` actualiza esos valores para ese equipo (no re-despliega los demás
automáticamente).

Los secretos/flags de la DMZ (`dmz-parking`, y los del wiki en `generate-wiki-vm.sh`) siguen
embebidos como literales en sus plantillas — no pasan por `.env.secrets` todavía porque la DMZ es
un único despliegue compartido, no N copias por equipo.

Provisioner (mencionado en la arquitectura de `snet-dmz-shared`) todavía no tiene imagen/Dockerfile
en ningún repo. CTFd sí tiene imagen (`sabana-corp-ctfd`, cuenta Docker Hub del operador) y está
implementado y validado end-to-end contra Azure real (ver `ctfd-vm/`/`generate-ctfd-vm.sh` arriba)
— ver `docs/plans/ctfd-deployment.md`. Monitor también está implementado y validado, ver
"Observabilidad" abajo (vive en `snet-mgmt`, no en `snet-dmz-shared`).

## Observabilidad (Prometheus + Grafana en `vm-monitor`)

F1+F2 implementados y validados contra Azure real (2026-08-10) — ver
`docs/plans/observability-monitoring.md` para el diseño completo.

- **`monitor/`** — cloud-init (Docker + Azure CLI), `prometheus/prometheus.yml`,
  `blackbox/blackbox.yml` (módulos `tcp_connect`/`http_2xx`/`ssh_banner`/`dns_udp`),
  `grafana/provisioning/` (datasource, dashboards "Muro de equipos"/"Muro DMZ", 7 reglas de
  alerta Unified Alerting) y `remote/gen_targets.py` (corre en `vm-monitor` cada 60s).
- **`templates/monitor-compose.yml.tpl`** / **`templates/monitor-gen-targets.service.tpl`** /
  **`generate-monitor.sh`** — mismo patrón que `generate-wiki-vm.sh`: resuelven las plantillas
  (`GRAFANA_ADMIN_PASSWORD`, `RESOURCE_GROUP`) y copian el resto de `monitor/` tal cual a
  `generated/monitor/`, que `lab-azure.sh` empaqueta (tar+base64) y empuja a `vm-monitor` en una
  sola invocación de `run-command` (mismo mecanismo que `sync_lab_dns`).
- **`gen_targets.py`** descubre servicios vía `az container list` (una sola llamada) y escribe
  `aci_targets.json` (file_sd de Prometheus) + `sabana_ip_drift`. El estado de control plane
  (`sabana_container_state`, `sabana_container_restart_count`) necesita `az container show` **por
  contenedor** — `az container list` no trae `instanceView` poblado (misma limitación que
  `print_container_states()` en `lab-azure.sh`) — así que se refresca cada 5 min (no en cada tick
  de 60s), paralelizado con un pool acotado y cacheado en disco, para no convertirse en 93
  llamadas/min al control plane.
- **Rutas de host que tienen que coincidir literalmente** entre `gen_targets.py` y
  `templates/monitor-compose.yml.tpl`: `/etc/prometheus/targets` y `/etc/node_exporter/textfile`.
  El script escribe ahí directamente (no en `/opt/monitor/...`) y el compose monta esas mismas
  rutas del host — un mismatch aquí deja los targets/métricas invisibles para los contenedores
  sin que ningún comando falle (ya pasó una vez en la validación de 2026-08-10, ver commit).
- Pendiente: `BotColgado` (requiere health endpoint en `bot.js`, repo `sabana-corp-network`) y
  `GatewaySinHandshakes` (requeriría más permisos que `Reader` para la managed identity). F3
  (`restore team/dmz`) y F4 (logs) sin implementar.

## DNS interno (dnsmasq en `vm-wg-gateway`)

Implementado — ver `docs/plans/internal-dns.md` para el diseño completo. Resumen operativo:

- **`generate-dns-hosts.sh`** — genera bloques de zona (formato `/etc/hosts`) en `generated/dns/`.
  Tres modos: `team <N> <ips...>` (escritura local, la usa `deploy_team_workload` con las IPs que
  ya tiene en la mano, sin llamadas a Azure — seguro en paralelo), `dmz` (lee `az container list` +
  la IP de `vm-wiki`), y `all-from-azure` (reconstruye todo desde una sola `az container list` —
  es lo que corre `dns-sync --from-azure`).
- **`sync_lab_dns()`** (en `lab-azure.sh`) — concatena todos los `generated/dns/*.hosts` y los
  empuja al gateway en **una sola** invocación de `az vm run-command invoke`
  (`yamls/wg-gateway/remote/apply-dns.sh.tpl`), sin importar cuántos equipos haya. Se llama al
  final de `deploy_dmz`, `deploy_team`, `create_wiki_vm`, y una vez en `add_team_range` (entre el
  paso paralelo de contenedores y el paso secuencial de peers WireGuard).
- **`./lab-azure.sh dns-sync [--from-azure]`** / **`dns-check <fqdn>`** — comandos manuales de
  sincronización y verificación (compara lo que resuelve el gateway contra la IP real de Azure).
- Dominio: `sabanacorp.internal` (variable `LAB_DOMAIN` en `lab-azure.sh`), **no** `.local` (mDNS
  se roba esas consultas en macOS/Linux con avahi).

**Las variables de entorno de los contenedores se quedan en IP a propósito** (`<DATABASE_IP>`,
`<WEBAPP_IP>` — ver sección siguiente): el DNS es una capa de nombres para humanos y navegación
dentro del CTF, no el plano de datos de los retos. Un dnsmasq caído no tumba ningún reto ya
desplegado.

## Orden de despliegue y resolución de IPs (lo que hace `lab-azure.sh` por ti)

ACI no da DNS entre container groups distintos — un YAML no puede referirse a otro por nombre, así
que un contenedor que depende de otro necesita su IP real. `deploy_team` en `lab-azure.sh` ya
hace esto automáticamente vía `sed` sobre el YAML generado:

1. `team<N>-database` → se lee su IP → se rellena `<DATABASE_IP>` en `team<N>-webapp.yaml` → se despliega `team<N>-webapp`
2. `team<N>-webapp` → se lee su IP → se rellena `<WEBAPP_IP>` en `team<N>-xss-bot.yaml` → se despliega `team<N>-xss-bot`
3. `team<N>-linux-server` — independiente

Los servicios DMZ (`dmz-filesrv`, `dmz-parking`, los 11 `dmz-decoy-*`) se despliegan en cualquier
orden (independientes). El wiki (`wiki` + `wiki-db`) no es un contenedor ACI — vive en una VM
en `snet-dmz-vm` con docker-compose (`deploy-wiki-vm`), donde la resolución de nombres entre
servicios es nativa vía la red `wiki_backend`.

Si se necesita hacerlo a mano (depuración):

```bash
az container show -g rg-ctf-semana-ingenieria-test -n <nombre> --query ipAddress.ip -o tsv
```

**Por qué esto sigue vigente aun con el DNS interno de arriba ya implementado**: el DNS resuelve
un nombre a una IP en tiempo de *consulta* (dnsmasq responde con lo que sabe ahora mismo); el
`sed` de arriba hornea una IP en tiempo de *despliegue* (queda fija dentro del YAML del
contenedor, no se vuelve a consultar). El registro DNS de `team7-database` solo puede existir
*después* de que Azure le asigne IP — igual que el `<DATABASE_IP>` de siempre — así que
`wait_for_ip` sigue siendo el 95% del tiempo y el 100% de la fragilidad de este paso. Lo único que
cambiaría si las env vars pasaran a FQDN sería mover el acoplamiento de "deploy time" a "runtime"
(cada reconexión de `webapp` a MySQL pasaría por dnsmasq) — evaluado y **descartado a propósito**
en `docs/plans/internal-dns.md` ("El huevo y la gallina").

## Pendiente / gaps conocidos

- **Persistencia — resuelto para `filesrv`**: usa una imagen propia (`maosuarez/sabanacorp-filesrv`)
  con el contenido de `file-srv/data` horneado vía Dockerfile — ya no depende del bind mount de
  docker-compose que ACI no soporta.
- **Persistencia — resuelto para `wiki` y `wiki-db`**: migrados de ACI a una VM con docker-compose
  (`deploy-wiki-vm`). Los volúmenes persistentes (`wiki_mariadb_data`, `wiki_bookstack_config`)
  funcionan nativamente en Docker plano, lo que resuelve tanto el problema de s6-overlay/PID1 como
  el de persistencia de configuración de BookStack (validado end-to-end 2026-08-08).
- **CTFd**: implementado y validado end-to-end contra Azure real (`deploy-ctfd-vm`, 2026-08-11) —
  ver `docs/plans/ctfd-deployment.md`. **Provisioner**: no implementado todavía en ningún repo.
  **Monitor**: implementado y validado, ver "Observabilidad" arriba.
- **Conector VPN**: resuelto. Gateway WireGuard implementado y validado end-to-end 2026-08-08
  (ver `docs/plans/wireguard-vpn-gateway.md`, comandos `deploy-wg-gateway` y `wg-team-peer` en
  `lab-azure.sh`).
- **Acceso desde la red interna**: cada contenedor ya tiene IP única dentro de su subred
  (`snet-dmz-shared` o `snet-team<N>`), pero el acceso real de un equipo a los servicios de la DMZ
  todavía depende de que las subredes de la VNet puedan enrutarse entre sí (peering/rutas dentro de
  `vnet-ctf-lab` — por defecto Azure ya enruta entre subredes de la misma VNet, pero falta validar
  NSGs si se añaden).
- **DNS interno**: validado end-to-end 2026-08-10 contra Azure real — Fase 0 (assumption checks) y
  Fase 1 (dnsmasq en VM viva sin recreación) completadas, zona sincronizada y round-trip verificado.
  Detalle en `docs/plans/internal-dns.md`. Caveat: contenedores pre-2026-08-10 no tienen `dnsConfig`
  aplicado (requeriría recreación); nuevos deploys lo reciben automáticamente.

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

`generated/` está en `.gitignore` (contiene secretos resueltos) — es la salida intermedia que
`lab-azure.sh` despliega con `az container create --file`, no se versiona.

**`templates/wiki-vm-compose.yml.tpl`** / **`generate-wiki-vm.sh`** / **`wiki-vm/cloud-init.yaml`**
— Validado end-to-end 2026-08-08, ver `docs/plans/wiki-on-vm.md`. Generan/despliegan
(`lab-azure.sh deploy-wiki-vm`) un docker-compose de wiki+wiki-db sobre una VM en `snet-dmz-vm`,
en vez de ACI (workaround al problema de s6-overlay/PID1 documentado en la memoria del proyecto).
La resolución de nombres entre `wiki` y `wiki-db` funciona nativamente vía la red de Docker
`wiki_backend` del compose, sin necesidad de inyección de IP.

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

CTFd, Provisioner y Monitor (mencionados en la arquitectura de `snet-dmz-shared`) todavía no
tienen imagen/Dockerfile en ningún repo — no se generó YAML para ellos.

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

## Pendiente / gaps conocidos

- **Persistencia — resuelto para `filesrv`**: usa una imagen propia (`maosuarez/sabanacorp-filesrv`)
  con el contenido de `file-srv/data` horneado vía Dockerfile — ya no depende del bind mount de
  docker-compose que ACI no soporta.
- **Persistencia — resuelto para `wiki` y `wiki-db`**: migrados de ACI a una VM con docker-compose
  (`deploy-wiki-vm`). Los volúmenes persistentes (`wiki_mariadb_data`, `wiki_bookstack_config`)
  funcionan nativamente en Docker plano, lo que resuelve tanto el problema de s6-overlay/PID1 como
  el de persistencia de configuración de BookStack (validado end-to-end 2026-08-08).
- **CTFd / Provisioner / Monitor**: no implementados todavía en ningún repo.
- **Conector VPN**: resuelto. Gateway WireGuard implementado y validado end-to-end 2026-08-08
  (ver `docs/plans/wireguard-vpn-gateway.md`, comandos `deploy-wg-gateway` y `wg-team-peer` en
  `lab-azure.sh`).
- **Acceso desde la red interna**: cada contenedor ya tiene IP única dentro de su subred
  (`snet-dmz-shared` o `snet-team<N>`), pero el acceso real de un equipo a los servicios de la DMZ
  todavía depende de que las subredes de la VNet puedan enrutarse entre sí (peering/rutas dentro de
  `vnet-ctf-lab` — por defecto Azure ya enruta entre subredes de la misma VNet, pero falta validar
  NSGs si se añaden).

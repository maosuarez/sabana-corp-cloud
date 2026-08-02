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
equipo): `filesrv`, `wiki-db`, `wiki`, `parking`, 11 `decoy-*`. Todas las imágenes son de la cuenta
Docker Hub `maosuarez` (`sabanacorp-filesrv`, `sabanacorp-wikidb`, `sabanacorp-parking`,
`sabanacorp-decoy`), construidas a partir del contenido de `sabana-corp-dmz`, salvo `wiki`
(`lscr.io/linuxserver/bookstack`, imagen pública genérica). Subred fija `snet-dmz-shared`.

**`generate-team.sh <N>`** / **`generate-dmz.sh`** — resuelven `${DOCKERHUB_USER}`,
`${DOCKERHUB_TOKEN}`, `${SUBSCRIPTION_ID}`, `${RESOURCE_GROUP}`, `${VNET}` (y `${TEAM}` en el caso
de team) sobre las plantillas correspondientes, escribiendo en `generated/`. `lab-azure.sh` los
llama con esas variables ya resueltas (`RG`, `VNET`, subscription id vía `az account show`); solo
hay que exportar `DOCKERHUB_USER`/`DOCKERHUB_TOKEN` y tener `.env.secrets` listo. Invocarlos a mano
solo hace falta para depurar la generación sin desplegar.

`generated/` está en `.gitignore` (contiene secretos resueltos) — es la salida intermedia que
`lab-azure.sh` despliega con `az container create --file`, no se versiona.

**`.env.secrets`** (gitignored, plantilla en `.env.secrets.example`) — flags y secretos de los
servicios **por equipo**, **compartidos por todos los equipos**: `add-team 1` y `add-team 2`
producen el mismo `FLAG_DATABASE`, `FLAG_WEBAPP_XSS`, etc. Solo cambia el nombre del container
group y la subred. Esto es intencional: CTFd valida una única flag por reto para todos los
equipos, así que cargarla una vez en CTFd sirve para cualquier instancia. Editar `.env.secrets` y
volver a correr `add-team <N>` actualiza esos valores para ese equipo (no re-despliega los demás
automáticamente).

Los secretos/flags de la DMZ (`dmz-wiki-db`, `dmz-parking`) siguen embebidos como literales en sus
plantillas — no pasan por `.env.secrets` todavía porque la DMZ es un único despliegue compartido,
no N copias por equipo.

CTFd, Provisioner y Monitor (mencionados en la arquitectura de `snet-dmz-shared`) todavía no
tienen imagen/Dockerfile en ningún repo — no se generó YAML para ellos.

## Orden de despliegue y resolución de IPs (lo que hace `lab-azure.sh` por ti)

ACI no da DNS entre container groups distintos — un YAML no puede referirse a otro por nombre, así
que un contenedor que depende de otro necesita su IP real. `deploy_dmz`/`deploy_team` en
`lab-azure.sh` ya hacen esto automáticamente vía `sed` sobre el YAML generado, en este orden:

1. `dmz-wiki-db` → se lee su IP → se rellena `<WIKI_DB_IP>` en `dmz-wiki.yaml` → se despliega `dmz-wiki`
2. `dmz-filesrv`, `dmz-parking`, los 11 `dmz-decoy-*` — independientes, cualquier orden
3. `team<N>-database` → se lee su IP → se rellena `<DATABASE_IP>` en `team<N>-webapp.yaml` → se despliega `team<N>-webapp`
4. `team<N>-webapp` → se lee su IP → se rellena `<WEBAPP_IP>` en `team<N>-xss-bot.yaml` → se despliega `team<N>-xss-bot`
5. `team<N>-linux-server` — independiente

Si se necesita hacerlo a mano (depuración):

```bash
az container show -g rg-ctf-semana-ingenieria-test -n <nombre> --query ipAddress.ip -o tsv
```

## Pendiente / gaps conocidos

- **Persistencia — resuelto para `filesrv` y `wiki-db`**: ambos usan ahora imágenes propias
  (`maosuarez/sabanacorp-filesrv`, `maosuarez/sabanacorp-wikidb`) con el contenido de
  `file-srv/data` y `wiki/init/bookstack_seed.sql` horneado vía Dockerfile — ya no dependen del
  bind mount de docker-compose que ACI no soporta.
- **Persistencia — pendiente para `wiki`**: BookStack sigue persistiendo su config/keys en
  `/config` (volumen en docker-compose); sin volumen persistente en ACI esos datos se pierden si
  el contenedor se reinicia. Aceptable para un evento de un día si no se reinicia; pendiente de
  decidir si se usa Azure File Share.
- **CTFd / Provisioner / Monitor**: no implementados todavía en ningún repo.
- **Conector VPN**: paso futuro, no diseñado.
- **Acceso desde la red interna**: cada contenedor ya tiene IP única dentro de su subred
  (`snet-dmz-shared` o `snet-team<N>`), pero el acceso real de un equipo a los servicios de la DMZ
  todavía depende de que las subredes de la VNet puedan enrutarse entre sí (peering/rutas dentro de
  `vnet-ctf-lab` — por defecto Azure ya enruta entre subredes de la misma VNet, pero falta validar
  NSGs si se añaden) y, más adelante, del conector VPN hacia el exterior.

# Plan: despliegue y automatización de CTFd (flags/scoreboard)

## Estado

**F1 implementada del lado de `../sabana-corp-CTFd` (2026-08-10, ver anotación al final del
documento). F2 — validada end-to-end contra Azure real (2026-08-11, ver última anotación):
`vm-ctfd` desplegada en `snet-dmz-vm`, `/setup` + admin + 5 challenges/flags cargados sin ningún
click manual.** F3/F4 — CI de imagen propia (cuenta Docker Hub pendiente), operación del evento —
siguen en diseño.

Este documento nació de una sesión de planeación (2026-08-10): entender el repo
`../sabana-corp-CTFd` (fork de CTFd oficial) y decidir cómo encaja en la infraestructura que ya
existe en este repo, antes de escribir una sola línea de automatización.

Decisión ya tomada en la sesión de planeación (ver "Equipos competidores" abajo): **auto-registro
abierto**, sin automatización de creación de equipos.

## Qué es `../sabana-corp-CTFd`

Fork de [CTFd/CTFd](https://github.com/CTFd/CTFd) (`origin` → `Kings0401/CTFd-Sabanus`), casi
vanilla: 2 commits propios sobre upstream, ambos de configuración, ninguno toca código Python de
la app (`CTFd/`):

1. `docker-compose.yml` parametrizado con `.env` (puerto, `SECRET_KEY`, credenciales de DB) en vez
   de los literales `ctfd`/`ctfd`/`ctfd` que trae upstream.
2. Eliminado un workflow heredado (`mirror-core-theme.yml`) que no aplica a este fork.

No hay automatización de challenges, flags ni equipos todavía — CTFd tal cual se clona requiere
crear cada reto a mano por la UI de admin. Ese es el hueco que cierra este plan.

## Motivación

`CLAUDE.md` de este repo ya lista **CTFd (flags y scoreboard)** como servicio compartido de
`snet-dmz-shared`, marcado "no implementado todavía". Las 5 flags reales del evento ya existen
como variables de entorno en `yamls/.env.secrets` (plantilla en `yamls/.env.secrets.example`) y
alimentan los contenedores de cada equipo — pero nadie las ha cargado en una plataforma de
scoring. Sin esto, el evento no tiene forma de validar ni puntuar una flag entregada por un
participante.

Dos preguntas del usuario delimitan el alcance de este plan:

1. ¿Cómo se despliega CTFd en Azure (Web App, ACI, o VM) de la mejor forma posible?
2. ¿Cómo se **precrean** en CTFd los espacios (challenges) para cada una de las flags que ya
   existen en `yamls/.env.secrets`, y cómo se crean los equipos competidores?

## Decisión de diseño: destino de despliegue — VM con docker-compose

Tres opciones evaluadas:

**a) Azure Web App for Containers.** Descartada. El modelo de Web App es de servicio público por
defecto (endpoint HTTPS público); ocultarlo detrás de la VNet-sin-internet del lab (arquitectura
de este repo: "se llega tras romper un portal cautivo y autenticarse por VPN") exigiría VNet
integration + private endpoint + deshabilitar acceso público — más superficie a mantener que
simplemente sumar una VM, que es justo el patrón que este repo ya resolvió dos veces. Además el
soporte de Web App para "multi-container vía docker-compose" (necesario para el stack real de
CTFd: app + MariaDB + Redis + nginx) es un modo semi-heredado de App Service, no la forma
recomendada actual de Azure para stacks con estado.

**b) Azure Container Instances**, siguiendo la convención "1 YAML = 1 contenedor = 1 IP" del
resto del repo. Descartada por ahora. Igual que con el wiki
(`docs/plans/wiki-on-vm.md`), CTFd necesita: persistencia real (MariaDB con los datos del evento,
uploads de archivos adjuntos de challenges) y aislamiento de red interno (`app` habla con `db` y
`cache` en una red que no debe quedar expuesta en la VNet compartida). Llevarlo a ACI exigiría (i)
partir el `docker-compose.yml` de CTFd en 3-4 YAML de contenedor individual, (ii) resolver la
dependencia de IP entre ellos con el mismo `sed` que usa `deploy_dmz`/`deploy_team` (frágil, un
paso más de mantenimiento), y (iii) reemplazar los volúmenes locales por Azure Files para que los
datos sobrevivan a un restart — tres piezas de complejidad nueva que la opción (c) no necesita
porque CTFd **ya trae su propio `docker-compose.yml` completo y probado por upstream**.

**c) VM con `docker-compose` (el `docker-compose.yml` que el propio repo CTFd ya trae).**
Elegida. Mismo patrón exacto que `vm-wiki` (`docs/plans/wiki-on-vm.md`) y `vm-monitor`
(`docs/plans/observability-monitoring.md`): cloud-init instala Docker, se copia/genera el compose,
`docker compose up -d` vía `az vm run-command invoke`. Cero piezas nuevas de diseño — es
replicar un patrón ya validado end-to-end dos veces contra Azure real, con la ventaja añadida de
que aquí ni siquiera hay que escribir el `docker-compose.yml` a mano: ya existe en
`../sabana-corp-CTFd/docker-compose.yml`, mantenido por upstream.

### Ubicación de red

`snet-dmz-shared` está delegada a `Microsoft.ContainerInstance/containerGroups` (exclusiva, ver
`docs/plans/wiki-on-vm.md`) — una VM no puede ir ahí, mismo choque que tuvo el wiki. En vez de
crear una tercera subred, **reusar `snet-dmz-vm` (`10.51.0.0/24`)**, que ya existe exactamente
para esto: "DMZ paralela para servicios que no corren en ACI". `vm-ctfd` viviría junto a `vm-wiki`
en la misma subred, sin necesidad de una subred nueva ni de tocar `create_vnet`.

Abierto: ¿una VM nueva (`vm-ctfd`) o coexistir en `vm-wiki` corriendo un segundo
`docker-compose.yml`? Se recomienda **VM separada** — CTFd trae su propia MariaDB y Redis; meterlo
en la misma VM que BookStack+MariaDB del wiki duplica el patrón de aislamiento por red bridge de
Docker que cada compose ya resuelve solo, sin ganar nada a cambio salvo un poco de cuota de vCPU
(hay margen: 6/10 vCPU en uso hoy según `docs/plans/observability-monitoring.md` "Costo y cuota").

## Decisión de diseño: cómo se precrean los challenges/flags

Este es el corazón de la pregunta del usuario. Opciones evaluadas:

**a) `ctfcli` (herramienta oficial de CTFd para "challenges as code").** Descartada. Su modelo es
para retos que **son** el contenido a subir (archivos adjuntos, imagen Docker del propio reto,
`challenge.yml` con `image:`/`build:`). Los "retos" de Sabana Corp no son eso — son servicios de
infraestructura ya en vivo (`webapp`, `database`, `linux-server`) que `lab-azure.sh` despliega por
su cuenta; en CTFd solo necesitan existir como **entrada de puntaje** (nombre, categoría,
descripción, flag). Adoptar `ctfcli` traería un formato y un flujo pensados para un caso que no es
el nuestro, sin resolver nada que un script simple no resuelva mejor.

**b) Import/export de CTFd (`export_ctf`/`import_ctf`, backup en `.zip`).** Descartada como fuente
de verdad. Es un formato de backup completo de la instancia (usuarios, submissions, config), no un
manifiesto legible ni diffeable en git — no encaja con "plantillas + generadores" (decisión ya
registrada en `CLAUDE.md` de este repo). Puede servir más adelante como backup operativo entre
ediciones del evento, pero no como definición de challenges.

**c) Script propio contra la API REST admin de CTFd (`/api/v1/challenges`, `/api/v1/flags`),
idempotente, leyendo un manifiesto declarativo versionado.** Elegida — mismo espíritu que
`generate-team.sh`/`generate-dmz.sh`: una fuente de verdad declarativa + un generador/aplicador,
nada de estado a mano por la UI.

### Diseño del manifiesto y el seed

- **Manifiesto** (`../sabana-corp-CTFd/challenges/challenges.yml`, vive en el repo de CTFd, no en
  este): un challenge por flag, referenciando el **nombre** de la variable de flag
  (`FLAG_WEBAPP_XSS`), nunca su valor.

  ```yaml
  - name: "Web App — Stored XSS"
    category: "Web Application"
    flag_env: FLAG_WEBAPP_XSS
    value: 100
    state: hidden   # visible solo cuando el staff publica el evento
    description: |
      ...
  - name: "Web App — LFI en adjuntos"
    category: "Web Application"
    flag_env: FLAG_WEBAPP_LFI
    value: 50
    state: hidden
  - name: "Base de Datos"
    category: "Base de Datos"
    flag_env: FLAG_DATABASE
    value: 100
    state: hidden
  - name: "Linux Server — root"
    category: "Linux Server"
    flag_env: FLAG_LINUXSERVER_ROOT
    value: 150
    state: hidden
  - name: "Linux Server — flag en proceso"
    category: "Linux Server"
    flag_env: FLAG_LINUXSERVER_PROC
    value: 25
    state: hidden
  ```

  Puntos (`value`) y descripciones son responsabilidad de quien organiza el evento, no de este
  documento — quedan como placeholder.

- **Seed script** (`../sabana-corp-CTFd/scripts/seed_challenges.py` o similar, en el repo de
  CTFd): lee `challenges.yml`, lee los valores reales de flag desde `yamls/.env.secrets` (en
  **este** repo, gitignored — el script recibe la ruta o las variables ya exportadas, nunca las
  hardcodea), y llama a la API admin de CTFd (`Authorization: Token <admin_api_token>`) para
  crear/actualizar cada challenge + su flag. Idempotente: si el challenge ya existe (match por
  `name`), actualiza en vez de duplicar — necesario porque el script se va a correr más de una vez
  (ediciones futuras del evento, cambio de puntaje, typo en la descripción).
- **Explícitamente fuera del seed**: `PIVOT_SSH_PASSWORD` y `BOT_SECRET` no son flags de score —
  son secretos de progresión (terminología de `sabana-corp-network/CLAUDE.md`, "Reglas para
  mantener consistencia entre flags"). No generan challenge en CTFd.
- **Challenges nacen ocultos** (`state: hidden`). Un segundo comando del mismo script (o un flag
  `--publish`) los pasa a `visible` — separar "cargar contenido" de "abrir el CTF al público" para
  no exponer nombres/categorías de reto por accidente antes del arranque del evento.
- Fuente del token admin — **automatizado 2026-08-10, ver anotación al final**: `CTFD_PRESET_ADMIN_TOKEN`
  en `yamls/.env.secrets`, no un Access Token generado a mano por el staff. CTFd expone
  `PRESET_ADMIN_TOKEN` justamente para este caso (variable de entorno que actúa como token de un
  admin creado al vuelo) — vive junto a los demás secretos del evento, nunca commiteado. Ver
  "Riesgos" abajo.

## Equipos competidores — auto-registro abierto (decidido en esta sesión)

En CTFd, un "equipo" (`user_mode=teams`) es solo un grupo de puntuación: nombre + password de
ingreso que los propios participantes eligen al registrarse, sin relación automática con
`team1..teamN` de la red de este repo. Esto es así porque las flags son **idénticas para todos los
equipos** (`yamls/.env.secrets` no varía por `${TEAM}`, ver `CLAUDE.md`) — CTFd no necesita saber
en qué subred/túnel WireGuard está cada participante para poder puntuar su flag.

Decisión: **auto-registro abierto**, sin automatización nueva de creación de equipos. Es el flujo
default de CTFd (`Setup` → `user_mode: teams`) y no requiere script ni credenciales
pre-distribuidas.

Configuración a definir en el setup inicial de CTFd (una vez, por la UI, no automatizada — no vale
la pena un script para algo que se hace una sola vez por edición del evento):

- `user_mode: teams`, `registration_visibility: public`.
- `team_size`: límite de integrantes por equipo (definir según el evento).
- `verify_emails`: probablemente `false` — evento cerrado dentro de un CTF universitario de un
  día, la fricción de verificación por correo no aporta nada aquí.

**Advertencia operativa** (no es un problema técnico, es una nota para el staff del evento): el
nombre de equipo que un participante elige en CTFd no coincide automáticamente con el `teamN` de
su túnel WireGuard/subred. Es aceptable porque el sistema no lo necesita, pero conviene pedirle a
cada equipo — como instrucción del evento, no como control técnico — que use su número de red como
nombre de equipo en CTFd, solo para que el staff pueda cruzar el scoreboard con la infraestructura
a simple vista si hace falta soporte.

## CI/CD

Convención ya establecida y documentada en `sabana-corp-network/CLAUDE.md` ("Convenciones para
CI/CD"), que este plan adopta tal cual para mantener los 3 repos del proyecto consistentes:

- Build + push de imagen en cada push a `main` (no en `release`, a diferencia del `docker-build.yml`
  actual del fork — ver hallazgo abajo).
- Tags `<usuario-dockerhub>/<imagen>:latest` + `:<sha-corto>`.
- Los workflows nunca usan valores reales de flags/secretos — solo `.env.example`/defaults
  ficticios; los secretos reales se inyectan en el despliegue real, fuera de CI.

### Hallazgo: CI heredado de upstream está roto en este fork, sin que nadie lo haya notado

`../sabana-corp-CTFd` tiene 7 workflows heredados de CTFd/CTFd. De esos, **6 nunca corren**:
`mariadb.yml`, `mysql.yml`, `mysql8.yml`, `postgres.yml`, `sqlite.yml`, `verify-themes.yml` están
todos activados con `branches: [master]` — el fork usa `main` como rama por defecto. Ningún push a
`main` ni PR contra `main` los dispara jamás. Solo dos workflows sí corren hoy:

- `lint.yml` — activado con `on: [push, pull_request]` sin filtro de rama, sí corre.
- `docker-build.yml` — activado con `on: release: types: [published]`, publica
  `${GITHUB_REPOSITORY,,}` (hoy `kings0401/ctfd-sabanus`) a Docker Hub + GHCR usando secretos
  `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` del repo de GitHub — corre solo si alguien publica un
  GitHub Release, que no ha pasado nunca en este fork.

Dos decisiones pendientes, no tomadas en esta sesión (son del dueño del repo/evento, no técnicas):

1. **Qué hacer con los 6 workflows muertos.** Opciones: (a) retarget a `main` para recuperar la
   cobertura de tests de upstream sobre este fork, (b) eliminarlos porque este fork no piensa
   mergear activamente de upstream CTFd y mantener 5 matrices de DB distintas (solo se despliega
   con MariaDB, ver `docker-compose.yml`) no aporta valor real — coherente con la memoria de
   proyecto "docs deben reflejar la realidad probada: eliminar artefactos muertos en vez de
   documentarlos".
2. **Cuenta de Docker Hub destino.** `docker-build.yml` hoy publica bajo el nombre del repo de
   GitHub (`kings0401/...`), no bajo `maosuarez` (la cuenta que usa el resto del proyecto para
   `sabanacorp-*`, ver `CLAUDE.md` de este repo, "Decisión de diseño: plantillas + generadores").
   Definir si la imagen de CTFd se publica en `maosuarez/sabanacorp-ctfd` (consistente con el
   resto) o se queda en la cuenta del dueño de `sabana-corp-CTFd` — afecta qué secretos de GitHub
   Actions hay que configurar y en qué cuenta.

Propuesta concreta para cuando se decida lo anterior (no implementada): reemplazar
`docker-build.yml` por un workflow `push a main` estilo `sabana-corp-dmz/docker-publish.yml` /
`sabana-corp-network/build-push.yml` — un solo job, sin matrix (una sola imagen), tags
`:latest` + `:<sha-corto>`.

## Integración futura con `lab-azure.sh`

No implementado, solo el esqueleto de qué haría falta, para no repetir diseño cuando se decida
ejecutar esto:

- `deploy-ctfd-vm`: mismo patrón que `deploy-wiki-vm`/`deploy-monitor-vm` — crea `vm-ctfd` en
  `snet-dmz-vm`, cloud-init instala Docker, copia/genera el `docker-compose.yml` (usando la imagen
  publicada por CI en vez de build local en la VM, más rápido y reproducible), variables desde un
  bloque nuevo `CTFD_*` en `yamls/.env.secrets` (puerto, `SECRET_KEY`, credenciales de DB — mismo
  patrón que ya usa el `.env.example` del propio fork).
- Al final del despliegue: correr `seed_challenges.py` vía `az vm run-command invoke` (o desde el
  operador, contra la IP privada por el túnel admin) — mismo mecanismo ya usado en este repo para
  todo lo que toca una VM sin SSH.
- `status` de `lab-azure.sh` ganaría una sección para `vm-ctfd`, igual que ya tiene para
  `vm-wiki`/`vm-monitor`/gateway.

## Riesgos / abierto

- **Token admin del seed script — RESUELTO (2026-08-10)**: `CTFD_PRESET_ADMIN_TOKEN`
  (`yamls/.env.secrets`) reemplaza la generación manual del Access Token. CTFd lo acepta como
  Access Token de un admin que crea al vuelo si no existe (ver
  `CTFd/utils/security/auth.py:lookup_user_token`/`generate_preset_admin`), así que
  `create_ctfd_vm()` corre `seed_challenges.py` automáticamente sin login por navegador. Sigue
  siendo el mismo nivel de secreto que una password de admin — vive fuera de git, tratarlo como
  `MYSQL_ROOT_PASSWORD`.
- **El wizard de `/setup` también quedó automatizado (2026-08-10)**: `PRESET_ADMIN_TOKEN` no
  alcanza solo — CTFd bloquea *toda* request (incluida la API) hasta que `/setup` se completa (ver
  `needs_setup()` en `CTFd/utils/initialization/__init__.py`), y ese endpoint es un form HTML con
  CSRF atado a la sesión del navegador, no una API. En vez de scrapear el HTML,
  `scripts/seed_setup.py` (nuevo, en `../sabana-corp-CTFd`) replica la lógica de la vista
  `/setup` directo contra los modelos de CTFd (`set_config` + crear el `Admins`), corriendo
  *dentro* del contenedor `ctfd` (`docker compose exec ctfd python3 -`, necesita el paquete CTFd
  instalado — a diferencia de `seed_challenges.py`, que corre desde el host de la VM con solo
  `requests`+`PyYAML`). Fija `user_mode=teams`, `registration_visibility=public`,
  `verify_emails=false` (las decisiones de "Equipos competidores" arriba); usa
  `CTFD_EVENT_NAME`/`CTFD_EVENT_DESCRIPTION`/`CTFD_TEAM_SIZE` (`yamls/.env.secrets`) y el mismo
  admin que `PRESET_ADMIN_TOKEN` (incluso si corren en cualquier orden, no se duplica la cuenta —
  ambos matchean por email). Idempotente: si `is_setup()` ya es `true`, no toca nada, así que
  `deploy-ctfd-vm` es seguro de re-correr sin resetear el nombre/admin de una edición anterior.
- **Persistencia entre ediciones del evento**: CTFd guarda submissions/scoreboard en su MariaDB.
  Si `vm-ctfd` se destruye con `./lab-azure.sh down` (borra el RG completo, invariante del
  proyecto), se pierde el historial del evento salvo que se haga `export_ctf` antes — no
  decidido si eso se automatiza (cron en la VM, o paso manual al cerrar el evento).
- **`SECRET_KEY` de CTFd**: firma las sesiones de todos los usuarios registrados (staff y
  participantes). Rotarlo invalida sesiones activas — generarlo una vez por edición del evento y
  tratarlo como secreto, igual que `JWT_SIGNING_SECRET` de los retos.
- **Tamaño de `vm-ctfd`**: sin decidir, probablemente `Standard_D2s_v7` por consistencia con
  `vm-wiki`/`vm-monitor`/`vm-wg-gateway`, no por un cálculo real de carga (CTFd para un evento de
  un día con decenas de equipos es liviano).
- **Quién publica el evento (`state: hidden` → `visible`)**: decidir si es un flag del seed script,
  un botón en la UI de CTFd (ya existe, "Freeze"/fechas de inicio nativas de CTFd), o ambos — CTFd
  ya trae `start`/`end` de CTF nativos, puede que no haga falta nada nuevo aquí más que
  configurarlos en el setup inicial.

## Runbook del día del evento

Comandos reales, ya probados contra Azure (2026-08-11), para no tener que reconstruir este flujo
de memoria ese día.

**Despliegue desde cero** (no existe `vm-ctfd` todavía):

```bash
export DOCKERHUB_USER="..."
export DOCKERHUB_TOKEN="..."
# yamls/.env.secrets ya tiene que tener el bloque CTFD_* con valores REALES, no changeme_*
# (CTFD_SECRET_KEY, CTFD_DB_PASSWORD, CTFD_DB_ROOT_PASSWORD, CTFD_PRESET_ADMIN_PASSWORD,
# CTFD_PRESET_ADMIN_TOKEN, CTFD_EVENT_NAME) -- ver "Riesgos" arriba.

CTFD_SEED_PUBLISH=1 ./lab-azure.sh deploy-ctfd-vm   # sin esto, los challenges quedan ocultos
```

Sin `CTFD_SEED_PUBLISH=1`, los 5 challenges se cargan pero con `state=hidden` — **esto es
diseño, no un bug**: `/challenges` se ve vacío incluso logueado como admin hasta que se publican
(ver "Diseño del manifiesto y el seed" arriba, "cargar contenido" vs. "abrir el CTF"). Se
confundió con un error real en la validación de esta sesión — si vuelve a pasar, no es un
síntoma de que algo se rompió.

**Publicar (o volver a publicar) sin recrear la VM**, si ya está desplegada y solo hace falta
pasar los challenges de oculto a visible (o recargar un cambio en `challenges.yml`/flags):

```bash
TOKEN="$(grep ^CTFD_PRESET_ADMIN_TOKEN= yamls/.env.secrets | cut -d= -f2-)"
VM_IP="$(az vm list-ip-addresses -g rg-ctf-semana-ingenieria-test -n vm-ctfd \
  --query "[0].virtualMachine.network.privateIpAddresses[0]" -o tsv)"
az vm run-command invoke --resource-group rg-ctf-semana-ingenieria-test --name vm-ctfd \
  --command-id RunShellScript \
  --scripts "cd /opt/ctfd && CTFD_URL=http://localhost CTFD_API_TOKEN='${TOKEN}' python3 seed/seed_challenges.py --manifest seed/challenges.yml --env-file seed/flags.env --publish" \
  --query "value[0].message" --output tsv
```

Idempotente (match por `name`, no duplica) — seguro de correr más de una vez. Omitir `--publish`
si se quiere recargar contenido sin tocar la visibilidad actual.

**Verificar que responde** (por si el DNS interno no resuelve en el cliente — split-DNS de
WireGuard no es confiable en Linux, ver `docs/plans/internal-dns.md`):

```bash
google-chrome http://ctfd.dmz.sabanacorp.internal   # preferido, vía DNS interno
google-chrome http://<IP privada de vm-ctfd>/challenges   # fallback directo por IP
```

Login admin: `CTFD_PRESET_ADMIN_EMAIL` / `CTFD_PRESET_ADMIN_PASSWORD` (`yamls/.env.secrets`).

**Estado, si algo se ve raro**:

```bash
./lab-azure.sh status   # sección "DMZ-VM": vm-ctfd + estado de los 4 contenedores
az vm run-command invoke -g rg-ctf-semana-ingenieria-test -n vm-ctfd \
  --command-id RunShellScript --scripts 'docker compose -f /opt/ctfd/docker-compose.yml logs --tail 100 ctfd' \
  --query "value[0].message" -o tsv
```

**Ojo con `--output table`/confiar en el exit code de `az vm run-command invoke`**: no refleja si
el script remoto falló (ver anotación de abajo, bug 1) — siempre agregar
`--query "value[0].message" --output tsv` y leer el texto si algo no cuadra.

## Fases propuestas

### F1 — Manifiesto + seed script de challenges

- `challenges/challenges.yml` en `../sabana-corp-CTFd` con las 5 flags actuales.
- `scripts/seed_challenges.py`, idempotente, contra la API admin de CTFd.
- Documentar en `../sabana-corp-CTFd/CLAUDE.md` cómo generar el Access Token de admin la primera
  vez.

### F2 — VM real

- `deploy-ctfd-vm` en `lab-azure.sh`, `vm-ctfd` en `snet-dmz-vm`, validado end-to-end contra Azure
  real (mismo listón que wiki/monitor: no se marca "implementado" hasta correr de verdad).

### F3 — CI de imagen propia

- Decidir cuenta Docker Hub destino y qué hacer con los 6 workflows heredados rotos.
- Workflow `push a main` estilo `sabana-corp-network`/`sabana-corp-dmz`.

### F4 — Operación del evento

- Publicar/despublicar challenges, `export_ctf` antes de un `down`, y (si se decide) alinear
  nombre de equipo CTFd ↔ `teamN` como instrucción del evento, no como control técnico.

**F1 es el mínimo para poder cargar las flags reales sin clicks manuales.** F2 es lo que lo hace
desplegable. F3/F4 son higiene operativa, no bloquean un primer evento de prueba.

## Anotación (2026-08-10) — F1 y parte de F3 implementadas del lado de `../sabana-corp-CTFd`

Sesión de implementación en `../sabana-corp-CTFd` (no en este repo). Nada corrido contra Azure
real todavía — todo probado en local (dry-run del seed, `yaml`/`docker compose config` válidos).
Para continuar desde este lado (`sabana-corp-cloud`), esto es lo que ya existe y con qué contrato:

**F1 — manifiesto + seed script (hecho, coincide con el diseño de arriba):**

- `../sabana-corp-CTFd/challenges/challenges.yml` — las 5 flags de la tabla de este documento, una
  entrada por challenge, `flag_env: FLAG_*` (nunca el valor). `value`/`description` son
  placeholders puestos en esta sesión — pendiente que el organizador del evento los ajuste.
- `../sabana-corp-CTFd/scripts/seed_challenges.py` — idempotente (match por `name`/`challenge_id`
  contra `/api/v1/challenges` y `/api/v1/flags`), valida que **todas** las `FLAG_*` del manifiesto
  estén en el entorno antes de llamar a la API (aborta sin crear nada si falta alguna, lista solo
  los nombres). Dos formas de inyectar las flags: variables ya exportadas en el proceso, o
  `--env-file <ruta>` (hace `setdefault`, no pisa lo ya exportado) — pensado exactamente para
  apuntarlo a `yamls/.env.secrets` de este repo. Flags propias: `--dry-run` (valida sin llamar a la
  API), `--publish` (además marca todo `visible`).
- `../sabana-corp-CTFd/scripts/requirements.txt` — `requests` + `PyYAML`, separado del
  `requirements.txt` de la app porque el script no corre dentro del contenedor de CTFd.
- Requiere `CTFD_URL` + `CTFD_API_TOKEN` en el entorno (no en el `--env-file` de flags, aunque el
  loader los aceptaría igual si estuvieran ahí). **Automatizado 2026-08-10** (ver anotación al
  final): `create_ctfd_vm()` pasa `CTFD_URL=http://localhost` (corre en el host de `vm-ctfd`) y
  `CTFD_API_TOKEN=$CTFD_PRESET_ADMIN_TOKEN` — ya no hace falta login manual → Settings → Access
  Tokens.

**Parte de F3 — CI de imagen propia (hecho, decisión de cuenta Docker Hub sigue pendiente de tu lado):**

- Los 6 workflows heredados rotos (`mariadb.yml`, `mysql.yml`, `mysql8.yml`, `postgres.yml`,
  `sqlite.yml`, `verify-themes.yml`) y el `docker-build.yml` original (gated a `release: published`)
  fueron **eliminados**.
- `../sabana-corp-CTFd/.github/workflows/deploy.yml` — nuevo, `on: push` a `main` +
  `workflow_dispatch`, build+push `linux/amd64` a `<DOCKERHUB_USERNAME>/sabana-corp-ctfd:latest` y
  `:<sha>`. **Requiere que le inyectes los secrets de repo `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN`**
  en GitHub — hoy el workflow existe pero fallaría en el paso de login porque esos secrets no están
  configurados. Nombre de imagen fijo `sabana-corp-ctfd` bajo el namespace que sea `DOCKERHUB_USERNAME`
  (la decisión pendiente de "en qué cuenta publicar" ahora se resuelve solo con qué cuenta pongas
  en ese secret, no hay más código que tocar).

**Bonus fuera del alcance original del plan, útil para F2:**

- `../sabana-corp-CTFd/docker-compose.prod.yml` — variante de producción del compose de CTFd: hace
  `pull` de `${DOCKERHUB_IMAGE}:${IMAGE_TAG}` (la imagen que publica `deploy.yml`) en vez de
  `build: .`, y no monta el código fuente como volumen. Es exactamente lo que `deploy-ctfd-vm`
  debería copiar/generar en `vm-ctfd` según el diseño de "Integración futura con `lab-azure.sh`" de
  arriba.
- `../sabana-corp-CTFd/.env.production.example` — plantilla de las variables que ese compose
  necesita (`DOCKERHUB_IMAGE`, `SECRET_KEY`, `DB_*`, `TRUSTED_HOSTS`, `PRESET_ADMIN_*`, etc.).
  Mapea 1:1 a lo que tendría que salir de un futuro bloque `CTFD_*` en `yamls/.env.secrets`
  (mencionado en "Integración futura con `lab-azure.sh`" arriba) — ese bloque todavía no existe en
  `yamls/.env.secrets.example` de este repo.

**Qué falta para que F2 se pueda ejecutar (todo del lado de este repo, `sabana-corp-cloud`):**

1. Añadir un bloque `CTFD_*` a `yamls/.env.secrets.example` (puerto, `SECRET_KEY`, credenciales de
   DB, `DOCKERHUB_IMAGE`) siguiendo el formato de `.env.production.example` de arriba.
2. `deploy-ctfd-vm` en `lab-azure.sh`: crear `vm-ctfd` en `snet-dmz-vm`, cloud-init con Docker,
   copiar `docker-compose.prod.yml` + `.env` generado desde `yamls/.env.secrets`, `docker compose
   up -d` vía `az vm run-command invoke` (mismo patrón que `deploy-wiki-vm`/`deploy-monitor-vm`).
3. Al final de ese despliegue, invocar `seed_challenges.py --env-file yamls/.env.secrets --publish`
   (o sin `--publish` si el evento no arranca todavía) contra la IP privada de `vm-ctfd` — requiere
   resolver primero cómo se obtiene `CTFD_API_TOKEN` sin intervención manual (punto abierto de F1
   arriba) o aceptar que ese paso sigue siendo manual.
4. Configurar los secrets `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` en el repo de GitHub de
   `sabana-corp-CTFd` para que `deploy.yml` publique de verdad.

## Anotación (2026-08-10) — F2 escrita del lado de `sabana-corp-cloud`, no corrida contra Azure

Sesión de implementación en este repo, cerrando los 4 puntos de "Qué falta para que F2 se pueda
ejecutar" de arriba (excepto el 4, que es del lado del repo `sabana-corp-CTFd`/GitHub, fuera de
este). Todo probado localmente (render de `yamls/generated/ctfd/docker-compose.yml` con
`envsubst`, validado como YAML) — **nada desplegado contra Azure real todavía**, así que sigue sin
haber `vm-ctfd`.

**Archivos nuevos:**

- `yamls/templates/ctfd-compose.yml.tpl` — adaptado de
  `../sabana-corp-CTFd/docker-compose.prod.yml` (nginx + ctfd/gunicorn + MariaDB + Redis), sin los
  defaults `${VAR:-default}` de docker-compose (`envsubst` no los entiende — se quitaron y los
  defaults ahora viven en el generador).
- `yamls/ctfd-vm/cloud-init.yaml` — mismo cloud-init que `yamls/wiki-vm/cloud-init.yaml` (Docker
  Engine + plugin compose).
- `yamls/ctfd-vm/conf/nginx/http.conf` — vendored tal cual desde
  `../sabana-corp-CTFd/conf/nginx/http.conf` (estático, sin variables).
- `yamls/generate-ctfd-vm.sh` — genera `yamls/generated/ctfd/{docker-compose.yml,
  conf/nginx/http.conf}`. A diferencia de `generate-wiki-vm.sh` (secretos literales), lee el
  bloque `CTFD_*` de `yamls/.env.secrets` — mismo mecanismo que `generate-team.sh`. Imagen
  resuelta como `${DOCKERHUB_USER}/sabana-corp-ctfd:${CTFD_IMAGE_TAG:-latest}`.

**Archivos editados:**

- `yamls/.env.secrets.example` — nuevo bloque `CTFD_*` (`CTFD_SECRET_KEY`, `CTFD_DB_NAME`,
  `CTFD_DB_USER`, `CTFD_DB_PASSWORD`, `CTFD_DB_ROOT_PASSWORD`, `CTFD_PRESET_ADMIN_*`). El
  `yamls/.env.secrets` real (gitignored) del operador también recibió el bloque, con los mismos
  placeholders `changeme_*` — hay que rellenarlo con valores reales antes de desplegar.
- `yamls/generate-dns-hosts.sh` — el caso `dmz` y `all-from-azure` ahora también resuelven la IP
  de `vm-ctfd` (si existe) y registran `ctfd.dmz.${LAB_DOMAIN}` (alias `scoreboard.dmz`), mismo
  patrón que `wiki.dmz`.
- `lab-azure.sh` — nueva función `create_ctfd_vm()` (mismo patrón que `create_wiki_vm()`: crea
  `vm-ctfd` en `snet-dmz-vm`, espera Docker via cloud-init, empuja el bundle tar+base64 vía
  `run-command`, `docker compose up -d`, registra DNS). Comando nuevo `deploy-ctfd-vm`, sección
  nueva en `status()`, usage string y comentario de cabecera actualizados.

**Qué falta para correr esto de verdad (no resuelto en esta sesión):**

1. Rellenar `yamls/.env.secrets` (bloque `CTFD_*`) con valores reales, no los placeholders
   `changeme_*` (incluye ahora `CTFD_PRESET_ADMIN_TOKEN`, `CTFD_EVENT_NAME` — ver anotación
   siguiente).
2. Confirmar que la imagen `${DOCKERHUB_USER}/sabana-corp-ctfd:latest` ya existe en Docker Hub
   (el usuario indicó que sí, bajo su cuenta) y que `DOCKERHUB_USER` apunta a esa cuenta al correr
   `./lab-azure.sh deploy-ctfd-vm`.
3. Correr `./lab-azure.sh deploy-ctfd-vm` contra Azure real y validar end-to-end (arranque de los
   4 servicios, `/setup` + Access Token + carga de challenges ya automatizados, ver anotación
   siguiente — falta la corrida real) antes de marcar F2 como implementada.
4. Punto 4 de "Qué falta" original (secrets `DOCKERHUB_USERNAME`/`DOCKERHUB_TOKEN` en el repo de
   GitHub de `sabana-corp-CTFd`) sigue pendiente y es independiente de este repo.

## Anotación (2026-08-10, continuación) — automatización completa del primer arranque (setup + token admin)

Mismo día, misma sesión: se cerró el hueco marcado arriba como manual (login admin → Settings →
Access Tokens) y además se encontró y cerró un hueco más grande que no estaba documentado —
CTFd bloquea *toda* request, incluida la API, hasta que el wizard de `/setup` se completa (ver
`needs_setup()` en `CTFd/utils/initialization/__init__.py`), así que un token de admin por sí solo
no alcanza para correr `seed_challenges.py` sin intervención humana.

**Archivos nuevos:**

- `../sabana-corp-CTFd/scripts/seed_setup.py` — replica la lógica de la vista `/setup` (crear
  admin, fijar `user_mode`/visibilidad/nombre del evento, marcar `config['setup']=true`) directo
  contra los modelos de CTFd, sin pasar por el form HTML (que exige un nonce CSRF atado a la
  sesión del navegador — automatizarlo con un cliente HTTP genérico hubiera significado scrapear
  ese nonce del HTML, fragil). Por eso corre *dentro* del contenedor `ctfd`
  (`docker compose exec -T ctfd python3 - < seed/seed_setup.py`), no desde el host de la VM como
  `seed_challenges.py` — necesita el paquete `CTFd` instalado y contexto de Flask/DB, no solo
  `requests`/`PyYAML`. Idempotente (`if is_setup(): return`), y si el admin que crea
  `PRESET_ADMIN_TOKEN` ya existe (mismo email), no lo duplica.

**Archivos editados (`sabana-corp-cloud`):**

- `yamls/templates/ctfd-compose.yml.tpl` — agregado `PRESET_ADMIN_TOKEN` (CTFd lo acepta como
  Access Token de un admin que crea al vuelo, ver `CTFd/utils/security/auth.py`) y
  `CTFD_EVENT_NAME`/`CTFD_EVENT_DESCRIPTION`/`CTFD_TEAM_SIZE` (no son variables nativas de CTFd,
  las lee `seed_setup.py`) al `environment` del servicio `ctfd`.
- `yamls/generate-ctfd-vm.sh` — `CTFD_PRESET_ADMIN_NAME/EMAIL/PASSWORD` pasaron de opcionales a
  obligatorias (el seed automático depende de que exista un admin válido), se agregó
  `CTFD_PRESET_ADMIN_TOKEN` (obligatoria) y `CTFD_EVENT_NAME` (obligatoria)/`CTFD_EVENT_DESCRIPTION`/`CTFD_TEAM_SIZE`
  (opcionales); ahora también vendorea `seed_setup.py` desde `$CTFD_REPO_DIR` junto a los otros
  archivos de `seed/`.
- `yamls/.env.secrets(.example)` — nuevas variables `CTFD_PRESET_ADMIN_TOKEN`,
  `CTFD_EVENT_NAME`/`CTFD_EVENT_DESCRIPTION`/`CTFD_TEAM_SIZE`. **Ojo con comillas**: `.env.secrets`
  se carga con `source` en bash (no es un parser `.env` real) — un valor con espacios como
  `CTFD_EVENT_NAME` tiene que ir entre comillas (`CTFD_EVENT_NAME="Sabana Corp CTF"`) o `source`
  rompe interpretando el resto como un comando. Ya corregido en ambos archivos; tenerlo en cuenta
  si se agregan más variables con espacios a este archivo en el futuro.
- `lab-azure.sh` — `create_ctfd_vm()` ahora corre, en orden, `seed_setup.py` (dentro del
  contenedor) y después `seed_challenges.py` (desde el host de la VM), entre el chequeo de "CTFd
  responde" y el mensaje final. Cloud-init de `vm-ctfd` gana `python3-pip` (ya estaba, sin cambios
  en esta pasada).

**Validado localmente**: `./yamls/generate-ctfd-vm.sh` corre limpio con `DOCKERHUB_USER` de
prueba, el `docker-compose.yml` resultante es YAML válido con las 4 variables nuevas resueltas, y
`seed_setup.py` vendored pasa un chequeo de sintaxis. **Nada corrido contra Azure real** — sigue
sin haber `vm-ctfd`, sigue siendo el paso 3 de la lista de arriba.

## Anotación (2026-08-11) — F2 validada end-to-end contra Azure real, tres bugs encontrados y corregidos

`./lab-azure.sh deploy-ctfd-vm` se corrió contra el lab real. La primera corrida terminó con exit
0 y el mensaje final de "éxito" — pero **eso no significaba que hubiera funcionado**: verificación
manual post-deploy (leer `value[0].message` de cada `run-command invoke` directamente en vez de
confiar en `--output table`/el exit code de `az`) encontró dos bugs reales, ambos corregidos y
re-validados contra la misma VM (sin recrearla, ver memoria de proyecto sobre aplicar en caliente):

1. **`az vm run-command invoke` no propaga el exit code del script remoto.** Confirmado con un
   `--scripts "exit 1"` de control: `az` devuelve exit 0 y `"code":
   "ProvisioningState/succeeded"` igual. El resultado real (éxito o traceback) vive solo en el
   texto de `value[0].message`. La primera versión de `create_ctfd_vm()` confiaba en el exit code
   de `az` para el loop de "¿CTFd ya responde?" y usaba `--output table` (que no mostró nada útil)
   para invocar `seed_setup.py`/`seed_challenges.py` — ninguno de los dos hubiera hecho fallar el
   deploy si el script remoto tronaba. Corregido: **todo** `run-command invoke` cuyo resultado
   importa ahora captura `--query "value[0].message" --output tsv`, lo imprime siempre (nada de
   salida silenciosa) y decide éxito/error inspeccionando el texto (código HTTP para el chequeo de
   salud, un marcador de éxito conocido para cada script) — no el exit code de `az`. Esta regla
   aplica a cualquier `run-command` nuevo que se agregue más adelante, no solo a los de CTFd.
2. **`TRUSTED_HOSTS` no incluía `localhost`.** `seed_challenges.py` y el chequeo de salud le pegan
   a CTFd por `http://localhost` (dentro de `vm-ctfd`, vía nginx), pero `TRUSTED_HOSTS` solo traía
   `ctfd.dmz.sabanacorp.internal` — Werkzeug devolvía `500 SecurityError: Host 'localhost' is not
   trusted` en cualquier request con ese Host header (ver `CTFd/__init__.py:create_url_adapter`).
   `seed_setup.py` no se vio afectado (no usa HTTP, escribe directo contra los modelos), pero
   `seed_challenges.py` sí — la carga de challenges de la primera corrida **nunca pasó de verdad**,
   aunque el deploy había reportado éxito. Corregido en `generate-ctfd-vm.sh`:
   `TRUSTED_HOSTS="ctfd.dmz.${LAB_DOMAIN},localhost"` (CTFd separa por comas, ver
   `CTFd/config.py`).

**Efecto colateral menor, no un bug**: `GET /` devuelve 404 (no 200) porque `seed_setup.py`
deliberadamente no crea la página `index` que sí crea la vista `/setup` original (se consideró
innecesaria para el CTF — el flujo real de los participantes es `/challenges`/`/login`, no la
home). Por eso el chequeo de salud apunta a `/api/v1/challenges` (devuelve 302, no 404) y no a
`/`.

**Resultado de la corrida real, verificado directamente contra `vm-ctfd` (no solo por los logs del
deploy)**: los 4 contenedores (`ctfd`, `nginx`, `db`, `cache`) corriendo; `seed_setup.py`
confirmado idempotente (`CTFd ya esta configurado` en una segunda corrida manual); los 5
challenges cargados con `state=hidden` y IDs estables entre corridas (`seed_challenges.py`
confirmado idempotente también); `ctfd.dmz.sabanacorp.internal` resuelve `10.51.0.4` desde
`dns-check`. **F2 queda validada end-to-end — mismo listón que wiki/monitor.** Pendiente real:
`.env.secrets` de este operador todavía tiene varios valores `changeme_*` (`CTFD_SECRET_KEY`,
`CTFD_DB_PASSWORD`, `CTFD_DB_ROOT_PASSWORD`, `CTFD_PRESET_ADMIN_PASSWORD`,
`CTFD_PRESET_ADMIN_TOKEN`) — esto fue una corrida de prueba, hay que rotarlos a valores reales
antes del evento real (mismo cuidado que `SECRET_KEY`/`MYSQL_ROOT_PASSWORD` documentado arriba).

**Tercer bug, encontrado por el usuario navegando de verdad (misma sesión)**: acceder a
`http://10.51.0.4` directo por IP (en vez del FQDN) también daba `500 SecurityError: Host
'10.51.0.4' is not trusted` — mismo mecanismo que el bug 2, pero con un Host header distinto.
Relevante porque el split-DNS de WireGuard **no es confiable en clientes Linux** (ver
`docs/plans/internal-dns.md`), así que navegar por IP no es un caso de borde raro, es un camino
real. Corregido: `create_ctfd_vm()` en `lab-azure.sh` ahora obtiene la IP privada de `vm-ctfd`
inmediatamente después de `az vm create` (antes se pedía más tarde, después de generar el bundle)
y se la pasa a `generate-ctfd-vm.sh` como `CTFD_VM_IP`, que la suma a `TRUSTED_HOSTS` —
`ctfd.dmz.${LAB_DOMAIN},localhost,${CTFD_VM_IP}`. Aplicado en caliente sobre la `vm-ctfd` ya viva
(regenerar bundle + `docker compose up -d`, sin recrear la VM) y verificado con `curl -H 'Host:
10.51.0.4'` devolviendo 302 en vez de 500.

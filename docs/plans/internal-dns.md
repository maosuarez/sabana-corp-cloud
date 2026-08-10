# Plan: DNS interno del lab (dnsmasq en vm-wg-gateway)

## Estado

**Diseño, no implementado.** Ninguna pieza de este documento existe todavía en el repo: hoy
`yamls/templates/*.yaml.tpl` no llevan `dnsConfig`, `yamls/wg-gateway/cloud-init.yaml` no
instala dnsmasq, y `lab-azure.sh:create_wg_peer()` (línea ~514) sigue rellenando
`CLIENT_DNS="1.1.1.1"` en el `.conf` de cada peer.

**Momento de ejecución: después de que la DMZ completa esté montada.** Es un requisito
explícito, no una preferencia de orden. Motivos concretos:

- La zona DNS se construye leyendo el estado real de Azure (`az container list` / las IPs que
  `deploy_team_workload` ya conoce). Montarla contra una DMZ a medias significa reescribirla
  entera cuando lleguen CTFd/Provisioner/Monitor, y arrastrar un esquema de nombres decidido
  sin conocer todos los servicios que hay que nombrar.
- Este plan **añade una dependencia nueva a `vm-wg-gateway`** (que hoy solo hace VPN). Meter esa
  dependencia mientras todavía se está estabilizando la DMZ mezcla dos superficies de fallo que
  conviene depurar por separado.
- Nada de la DMZ ni de los retos depende de este plan para funcionar (ver "Resiliencia"): es una
  capa de comodidad y de narrativa, no de plano de datos.

Prerrequisitos duros antes de empezar la Fase 1:

1. DMZ compartida desplegada y estable (`deploy-dmz` + `deploy-wiki-vm`).
2. `vm-wg-gateway` desplegada y validada end-to-end (ya lo está desde 2026-08-08, ver
   `docs/plans/wireguard-vpn-gateway.md`).
3. Al menos dos equipos desplegados (`team1`, `team2`) para poder probar el caso "resuelve pero
   no alcanza" que es el que define el modelo de seguridad.

## Problema

Hoy todo en el lab se direcciona por IP cruda, y eso duele en tres lugares distintos:

1. **Para los participantes y el staff.** Un equipo que entra por VPN recibe un `.conf` y una
   lista de IPs (`10.60.3.5:80`, `10.50.0.6:8080`, ...). No hay forma de decir "entra al
   helpdesk" sin decir también "que hoy es .5, pero si lo redesplegamos es otra". Rompe la
   ficción de "Sabana Corp es una empresa" — una empresa tiene nombres, no una hoja de cálculo
   de IPs — y convierte cualquier guía o pista del CTF en un documento que caduca con cada
   redespliegue. El propio repo ya vive esa ficción a medias: `wiki-vm-compose.yml.tpl` pone
   `APP_URL: "http://wiki-int.empresa.local"`, un nombre que **no resuelve en ninguna parte**.

2. **Para los contenedores dependientes.** `ACI no da DNS entre container groups distintos`
   (documentado en `CLAUDE.md` y en `yamls/README.md`), así que `deploy_team_workload()`
   despliega `database`, lee su IP con `wait_for_ip`, y la hornea con `sed` en el YAML de
   `webapp` (`lab-azure.sh:271`); lo mismo `webapp` → `xss-bot` (`lab-azure.sh:277`). La IP
   queda **congelada dentro del contenedor**, lo que produce el fallo silencioso que
   `docs/plans/observability-monitoring.md` ya bautizó `DerivaDeIP`: si `team7-database` se
   recrea con otra IP, `team7-webapp` sigue Running, sigue devolviendo 200 en `/`, y solo falla
   al tocar la base.

3. **Para operar el evento.** Diagnosticar "el reto 1 del equipo 14" implica cruzar
   `az container list` con la memoria del operador. Con nombres, es `curl
   http://helpdesk.team14.<dominio>`.

Este documento resuelve (1) y (3) de forma completa, y (2) **solo parcialmente y a propósito** —
la sección "El huevo y la gallina" explica por qué, y por qué eso está bien.

## Decisión de diseño: dnsmasq en vm-wg-gateway, zona plana, servida a la VNet y al túnel

Un único `dnsmasq` en `vm-wg-gateway`, escuchando en `wg0` (para los clientes VPN) y en `eth0`
(para los contenedores ACI), sirviendo una zona plana de registros A generados desde el estado
real de Azure, y reenviando todo lo demás a Azure DNS (`168.63.129.16`).

Por qué en `vm-wg-gateway` y no en una VM propia:

- Es **la única máquina que ya está en el camino de todos**: los clientes VPN salen de ahí y
  toda la VNet la alcanza. Un `dns-server` aparte añadiría una VM (2 vCPU de una cuota de 10,
  ver `docs/plans/wiki-on-vm.md`) para un proceso que consume ~15 MB de RAM.
- Ya existe la maquinaria de escribir en esa VM (`az vm run-command invoke` +
  `yamls/wg-gateway/remote/*`), validada end-to-end.
- Su IP en el overlay (`10.200.0.1`) es **fija por diseño** (la fija `cloud-init.yaml`), así que
  el `DNS =` del cliente WireGuard es una constante, no un valor que haya que descubrir.
- Si el gateway se cae, ya no hay lab desde afuera de todas formas — el DNS no añade un punto
  único de falla *nuevo* para el acceso remoto. (Sí lo añadiría para los contenedores; ver
  "Resiliencia", que es exactamente el motivo de mantener las env vars en IP.)

### Alternativas descartadas

**Azure Private DNS Zone.** Descartada por dos razones independientes, cualquiera de las dos
basta:
- Los container groups de ACI inyectados en una VNet **no se auto-registran** en una Private DNS
  Zone (el auto-registro de los virtual network links solo cubre NICs de VM). Habría que crear
  cada registro A a mano con `az network private-dns record-set a add-record` — o sea, el mismo
  trabajo de sincronización que con dnsmasq, pero contra el control plane de Azure y con su
  latencia, sin ganar nada.
- Una Private DNS Zone solo se resuelve preguntando a `168.63.129.16`, que es una dirección
  *link-local de plataforma*: solo responde a recursos dentro de la VNet. **Desde el PC del
  participante, al otro lado del túnel WireGuard, es inalcanzable.** Y el requisito 1 de este
  plan es precisamente resolver desde el PC del operador/equipo. Se podría montar un forwarder en
  el gateway que reenvíe a `168.63.129.16`... que es literalmente dnsmasq, pero con el doble de
  piezas y una zona más que mantener.

**`/etc/hosts` generado y repartido.** Descartada. Funciona para los contenedores (habría que
montarlo, y ACI no soporta bind mounts de archivos sueltos) y sobre todo **no funciona para el
participante**: implicaría pedirle a cada equipo que edite `/etc/hosts` o
`C:\Windows\System32\drivers\etc\hosts` como root/admin, en máquinas que no controlamos, y
volver a hacerlo cada vez que una IP cambie. Además convierte cada cambio de IP en un incidente
de soporte durante el evento en vez de en una línea de archivo en el gateway.

**CoreDNS (en ACI o en la VM).** Descartada por sobre-ingeniería para este tamaño. CoreDNS aporta
sobre dnsmasq: plugins de vista (`view`), integración con Kubernetes, y métricas Prometheus
nativas. Nada de eso se usa aquí — no hay Kubernetes, la decisión de "sin split-horizon" (abajo)
elimina la necesidad de `view`, y las métricas de DNS no están en el diseño de
`docs/plans/observability-monitoring.md`. A cambio pediría: gestionar un Corefile + zonas, o
correrlo en ACI (donde no puede escuchar en `wg0` y volvemos al problema del túnel). dnsmasq lee
archivos en formato `/etc/hosts`, que es el formato más simple que existe para generar con bash
y para leer a las 3 AM del día del evento.

**Un dnsmasq por equipo (para split-horizon).** Descartada; ver "Aislamiento".

## Esquema de nombres

### Dominio: `sabanacorp.internal` — explícitamente **no** `.local`

`.local` está reservado por RFC 6762 para **mDNS/Bonjour**. En macOS (siempre) y en muchas
distros Linux con `avahi`/`nss-mdns` instalado (Ubuntu de escritorio, por defecto), una consulta
a `algo.local` **no se manda al servidor DNS configurado**: se resuelve por multicast en la red
local. El resultado sería exactamente el peor tipo de bug para un evento: funciona en la máquina
del operador (WSL2, sin avahi), falla en el MacBook de un participante, y el síntoma es "a veces
resuelve" sin nada en los logs del gateway.

`.internal` fue designado por ICANN (2024) como TLD reservado permanentemente para uso privado —
nunca será delegado, ningún resolver público lo va a secuestrar, y ningún stack de SO lo
intercepta. Se usa `sabanacorp.internal`.

El dominio vive en **una sola variable** (`LAB_DOMAIN` en `lab-azure.sh`, exportada a los
generadores), así que cambiarlo es una edición y un `dns-sync`. Nota: hay que alinear
`yamls/templates/wiki-vm-compose.yml.tpl` (`APP_URL: http://wiki-int.empresa.local`), que hoy
apunta a un nombre inventado que no resuelve.

### Formato

| Qué | FQDN canónico | Alias adicionales |
|---|---|---|
| webapp de equipo N | `webapp.team<N>.sabanacorp.internal` | `helpdesk.team<N>...` |
| database de equipo N | `database.team<N>.sabanacorp.internal` | `db.team<N>...` |
| linux-server de equipo N | `linux-server.team<N>.sabanacorp.internal` | `pivot.team<N>...` |
| xss-bot de equipo N | `xss-bot.team<N>.sabanacorp.internal` | `bot.team<N>...` |
| filesrv (DMZ) | `filesrv.dmz.sabanacorp.internal` | `files.dmz...` |
| wiki (DMZ-VM) | `wiki.dmz.sabanacorp.internal` | `wiki-int.dmz...` |
| parking (DMZ) | `parking.dmz.sabanacorp.internal` | — |
| decoys (DMZ) | `<DECOY_NAME>.dmz.sabanacorp.internal` (`printer-01`, `admin-console`, `mail-old`, `backup-old`, `monitor-old`, `database-test`, ...) | `<perfil>.dmz...` (`printer`, `admin`, ...) |
| resolver del lab | `dns.sabanacorp.internal` → `10.200.0.1` | `gw.sabanacorp.internal` |

Regla mecánica de derivación desde el nombre del container group (lo que implementa el
generador), para que añadir un servicio nuevo no requiera decidir nada:

- `team<N>-<svc>` → `<svc>.team<N>.<LAB_DOMAIN>`
- `dmz-decoy-<x>` → `<x>.dmz.<LAB_DOMAIN>` (+ el `DECOY_NAME` narrativo como nombre canónico)
- `dmz-<x>` → `<x>.dmz.<LAB_DOMAIN>`

Los alias narrativos van en una tabla explícita dentro de `generate-dns-hosts.sh` (un array
asociativo de bash), no derivados — son decisiones de guion del CTF, no de infraestructura.

**El primer nombre de cada línea es el canónico**: dnsmasq genera el PTR (reverse) con él, así
que un `nmap -sL 10.60.3.0/24` o un `dig -x` desde dentro devuelve el nombre bonito. Es un
detalle de sabor deliberado (ver "Aislamiento").

### `snet-mgmt` no se publica

Ningún servicio de `snet-mgmt` (Monitor/Grafana, Provisioner, futuro jumpbox) recibe registro.
No como control de seguridad — el aislamiento real es `iptables` en el gateway — sino porque
publicarlos regala reconocimiento del plano de staff a cambio de cero beneficio para el
participante. El staff llega ahí por el túnel admin y por IP, o con un `/etc/hosts` local de
cuatro líneas.

## El huevo y la gallina: ¿desaparece el `sed`? (respuesta honesta: casi nada)

Este es el punto donde conviene ser explícito, porque la intuición ("con DNS ya no necesito IPs")
es falsa aquí.

### Qué hace hoy `deploy_team_workload()`

```
1. az container create team<N>-database
2. wait_for_ip team<N>-database            <- lee la IP (az container show, hasta 5 min de reintentos)
3. sed -i 's|<DATABASE_IP>|10.60.N.4|' team<N>-webapp.yaml      (lab-azure.sh:271)
4. az container create team<N>-webapp
5. wait_for_ip team<N>-webapp
6. sed -i 's|<WEBAPP_IP>|10.60.N.5|' team<N>-xss-bot.yaml       (lab-azure.sh:277)
7. az container create team<N>-xss-bot
```

### Qué haría con DNS "puro" (env vars con FQDN)

```
1. az container create team<N>-database
2. wait_for_ip team<N>-database            <- SIGUE IGUAL. No se puede registrar lo que no se sabe.
3. az vm run-command invoke ... escribe 10.60.N.4 database.teamN.<dom> en el gateway   <- NUEVO
4. (esperar a que dnsmasq recargue)                                                    <- NUEVO
5. az container create team<N>-webapp (con DB_HOST=database.teamN.<dom> ya en la plantilla)
6. ... idem para xss-bot
```

**Lo único que desaparece de verdad es el placeholder `<DATABASE_IP>` en el YAML y la línea de
`sed`.** El `wait_for_ip` —que es el 95% del tiempo y el 100% de la fragilidad de ese paso— no
desaparece: el registro DNS del dependiente solo puede existir *después* de que Azure le asigne
la IP. El huevo y la gallina no se rompe, se muda: en vez de "inyectar la IP en el YAML del
dependiente" (operación local, instantánea, sin dependencias externas, imposible de fallar por
red) pasa a ser "registrar la IP en un tercer sistema" (`az vm run-command invoke`: 5-15 s de
round-trip, serializado por VM, y por tanto **no paralelizable** — justo el paso que
`add-team-range` optimizó).

Y aparece un acoplamiento nuevo en **runtime**, no solo en deploy: hoy `webapp` lleva la IP de
`database` horneada y no le pregunta a nadie nada. Con FQDN, cada reconexión de `webapp` a MySQL
pasa por dnsmasq. Si dnsmasq está caído cuando `webapp` reinicia (`restartPolicy: OnFailure`), el
Reto 1 de ese equipo queda inutilizable por una causa que hoy es imposible.

### Qué se gana realmente

Un beneficio, pero es real y está documentado: **desacoplar el ciclo de vida**. Con FQDN, recrear
`team7-database` con otra IP ya no obliga a redesplegar `team7-webapp` — basta re-registrar. Eso
es exactamente el paso 3 del `restore` que propone `docs/plans/observability-monitoring.md`
("Siempre, al final: re-resolver e inyectar las IPs de las dependencias hacia abajo") y hace que
la alerta `DerivaDeIP` deje de ser crítica. Con `local-ttl` bajo (ver config), la propagación es
de segundos.

### Recomendación

**Las variables de entorno de los contenedores se quedan en IP. El `sed` se mantiene.** DNS es la
capa de nombres para humanos, herramientas y navegación dentro del CTF, no el plano de datos de
los retos.

Consecuencias de esta decisión, todas deliberadas:

- Un fallo total de dnsmasq **no rompe ningún reto ya desplegado**. Es la propiedad que hace que
  todo el resto de este plan sea seguro de implementar una semana antes del evento.
- El rollback es trivial y no toca contenedores (ver "Rollback").
- El paso 3 nuevo (registrar en dnsmasq) sale del camino crítico del despliegue: puede hacerse
  *después* de desplegar todo el equipo, en lote, en el paso secuencial, en vez de intercalado
  entre contenedor y contenedor.

Los contenedores **sí** reciben `dnsConfig` apuntando al gateway (Fase 3): eso es lo que permite
que un participante que pivotó a `linux-server` haga `curl http://filesrv.dmz.sabanacorp.internal`
y que el reconocimiento se sienta como una red corporativa real. Pero lo que el reto *necesita*
para funcionar (`DB_HOST`, `WEBAPP_BASE_URL`) sigue siendo una IP.

Única excepción evaluada y **no recomendada para el evento**: `WEBAPP_BASE_URL` del `xss-bot`
como FQDN, que haría más realista el Reto 1 (el bot navega a un dominio, no a una IP; las cookies
tienen dominio real). Es tentador y es el caso donde el FQDN aporta valor de juego, no solo
comodidad — pero convierte el DNS en prerrequisito del reto de XSS. Solo considerarlo si las
Fases 1-4 llevan semanas estables y hay margen para probarlo de verdad.

### `dnsConfig` en ACI: ¿es soportado?

Sí — `properties.dnsConfig` (`nameServers[]`, `searchDomains`, `options`) es parte del esquema de
container group y está pensado precisamente para container groups desplegados en VNet. Se
configura vía YAML/ARM (`az container create --file`), **no hay flag equivalente en la línea de
comandos**, lo cual encaja con que este repo ya despliega todo con `--file`. El `apiVersion:
2021-07-01` que usan las plantillas es posterior a su introducción.

Dos cosas que **hay que verificar contra la realidad antes de confiar** (Fase 0, con un
contenedor de prueba y `az container exec ... cat /etc/resolv.conf`):

1. Que al especificar `nameServers` propios, ACI **reemplaza** el resolver por defecto en vez de
   añadirlo. Es lo esperado, y es la razón por la que el diseño incluye `168.63.129.16` como
   segundo nameserver explícito: para no romper la resolución de salida a internet de los
   contenedores si dnsmasq no responde.
2. Que cambiar `dnsConfig` en un container group existente fuerza recreación (y por tanto nueva
   IP). Si es así —lo probable— aplicar la Fase 3 a equipos ya desplegados implica volver a
   correr `add-team <N>`, que ya re-lee IPs y re-inyecta con `sed`, así que se auto-repara solo.
   Documentarlo para no descubrirlo en caliente.

El pull de imágenes de Docker Hub lo hace el host de ACI, **no** el contenedor, así que
`dnsConfig` no puede romper el arranque de un contenedor por no poder resolver `index.docker.io`.
Esto es importante y conviene confirmarlo en Fase 0 desplegando un equipo completo con
`dnsConfig` y dnsmasq **apagado a propósito**.

## Arquitectura de resolución

```
PC del participante (Windows/Linux/macOS)
   │  DNS = 10.200.0.1, sabanacorp.internal      (solo el dominio del lab en Windows/macOS; ver "Split-DNS")
   ▼  (por el túnel; requiere 10.200.0.1/32 en AllowedIPs del cliente)
┌──────────────────────── vm-wg-gateway ────────────────────────┐
│  wg0 = 10.200.0.1/16   ◄── consultas de clientes VPN          │
│  eth0 = 10.10.0.4      ◄── consultas de contenedores ACI      │
│                                                               │
│  dnsmasq                                                      │
│    hostsdir=/etc/dnsmasq.hosts.d/   (inotify, sin recargas)   │
│      ├── dmz      (13 servicios + wiki en vm-wiki)            │
│      ├── teams    (4 registros × N equipos)                   │
│      └── infra    (dns./gw.)                                  │
│    local=/sabanacorp.internal/   → nunca reenvía la zona       │
│    no-resolv + server=168.63.129.16  → todo lo demás a Azure  │
└───────────────────────────────────────────────────────────────┘
   ▲                                        │
   │ dnsConfig.nameServers[0]=10.10.0.4     ▼ upstream
   │ dnsConfig.nameServers[1]=168.63.129.16   Azure DNS (168.63.129.16) → internet
contenedores ACI (snet-team<N>, snet-dmz-shared)
```

Dos detalles que no son opcionales:

- **`10.10.0.4` tiene que ser una IP estática.** Hoy `deploy_wg_gateway()` no la fija, y si la VM
  se recrea puede cambiar — lo que dejaría el `dnsConfig` de *todos* los contenedores apuntando a
  la nada (con fallback a Azure DNS, o sea: el lab entero deja de resolver nombres y nadie sabe
  por qué). Se fija con `--private-ip-address 10.10.0.4` en el `az vm create`
  (`snet-wg-gateway` = `10.10.0.0/28`; `.0` es red y `.1`-`.3` los reserva Azure, así que `.4` es
  la primera usable, que es justo la que asigna hoy por DHCP). Con eso, tanto `10.200.0.1` como
  `10.10.0.4` son constantes del diseño y no hay que descubrir nada en tiempo de generación.
- **El cliente de equipo tiene que rutear `10.200.0.1/32`.** Hoy `create_wg_team_peer()` pasa
  `"10.60.<N>.0/24 10.50.0.0/24 10.51.0.0/24"`, y `create_wg_peer()` usa ese mismo string tanto
  para las reglas `iptables` como para el `AllowedIPs` del cliente. `10.200.0.1` no está en
  ninguno de esos CIDR, así que **hoy un cliente de equipo no puede ni siquiera enviarle un
  paquete DNS al gateway**: el driver de WireGuard lo descarta en el propio cliente (exactamente
  el comportamiento documentado en `wireguard-vpn-gateway.md`, "el `AllowedIPs` del lado cliente
  es en sí mismo una capa de filtrado"). Hay que separar las dos listas: `AllowedIPs` del cliente
  = CIDRs permitidos **+ `10.200.0.1/32`**; reglas `iptables FORWARD` = solo los CIDRs (el
  tráfico al propio gateway es `INPUT`, no `FORWARD`, y no necesita regla nueva mientras la
  política de `INPUT` siga en `ACCEPT`). El peer `admin` ya cubre `10.200.0.1` porque su
  `10.0.0.0/8` lo contiene.

## Mecanismo de escritura de la zona y paralelismo

Este es el punto de riesgo real del plan, y es el mismo que ya obligó a dejar los peers
secuenciales en `add_team_range()`.

### La regla general que hay que dejar escrita

**Toda escritura sobre `vm-wg-gateway` va en un paso secuencial.** No es solo por corrupción de
archivos: `az vm run-command invoke` se ejecuta a través de la extensión RunCommand de la VM, que
**es de un solo hilo por VM** — dos invocaciones concurrentes contra la misma máquina se
serializan o fallan con un conflicto de operación en curso. Es la misma causa raíz del "Paso 3
(secuencial)" en la decisión de paralelismo de `CLAUDE.md`; conviene generalizarla ahí en vez de
repetirla por caso.

### Mecanismo elegido

Tres capas, cada una resolviendo un problema distinto:

**1. Archivos por bloque en `hostsdir`, no un archivo compartido.**
`dnsmasq --hostsdir=/etc/dnsmasq.hosts.d` lee *todos* los archivos del directorio en formato
`/etc/hosts` y —esto es lo importante— **los vigila con inotify**: un archivo nuevo o modificado
se carga automáticamente, sin `SIGHUP` y sin reiniciar el servicio. (Ojo con la trampa: `SIGHUP`
a dnsmasq recarga `/etc/hosts` y `addn-hosts`, pero **no** relee `/etc/dnsmasq.d/*.conf`; y
reiniciar dnsmasq en pleno evento es justo lo que no queremos. `hostsdir` evita ambas cosas.)
Ubuntu 22.04 trae dnsmasq 2.86; `hostsdir` existe desde 2.75.

Escritura **atómica obligatoria**: escribir a `/tmp/x` y `mv` al directorio final, para que
inotify nunca vea un archivo a medias. Un `cat > /etc/dnsmasq.hosts.d/teams` directo puede
disparar la lectura con el archivo truncado.

**2. La fase paralela escribe local; solo la secuencial toca el gateway.**
`deploy_team_workload()` ya conoce las IPs de sus 4 contenedores (las acaba de leer con
`wait_for_ip`). En vez de mandarlas al gateway ahí mismo —que serializaría el paso paralelo
contra la extensión RunCommand— escribe un archivo **propio de ese equipo** en el disco local:
`yamls/generated/dns/team<N>.hosts`. Cero contención: cada job en paralelo escribe un archivo
distinto, igual que hoy cada uno escribe sus propios `team<N>-*.yaml`.

**3. Un solo push por operación, no uno por equipo.**
`sync_lab_dns()` hace `cat yamls/generated/dns/*.hosts` → `yamls/generated/dns/lab.hosts`, lo
manda en **una sola** invocación de `run-command` (base64 dentro del script, mismo patrón ya
probado en `create_wiki_vm()`), y el script remoto lo instala atómicamente. Se llama:

- al final de `deploy_dmz()`
- al final de `deploy_team()` (camino de un solo equipo)
- en `add_team_range()`, **una vez**, entre el Paso 2 (paralelo) y el Paso 3 (peers)
- al final de `create_wiki_vm()`
- bajo demanda con `./lab-azure.sh dns-sync`

Coste para un rango de 100 equipos: **una** invocación (~10 s), no 100. El DNS no cambia la
curva de escalado de `add-team-range`; el cuello de botella sigue siendo el bucle de peers.

Protección extra barata: `flock` local sobre `yamls/generated/dns/.lock` en `sync_lab_dns()`, por
si algún día alguien la llama desde dos terminales.

### Por qué no las alternativas

- **Un archivo compartido en el gateway con append por equipo** (`>> /etc/dnsmasq.hosts.d/lab`):
  es el patrón que ya casi muerde a los peers en `wg0.conf`. Read-modify-write remoto,
  no idempotente (redesplegar un equipo duplica líneas o deja registros huérfanos con la IP
  vieja), y obliga a lógica de "borra las líneas de team7 y vuelve a añadirlas" con `sed` remoto.
  Reemplazo de archivo completo > edición in-place, siempre.
- **Un archivo por equipo en el gateway** (`/etc/dnsmasq.hosts.d/team<N>`): elimina la corrupción
  de archivo pero **no** el cuello de botella de RunCommand — siguen siendo N invocaciones
  secuenciales. Se descarta como camino principal, pero es la salida natural si el push único
  choca con el límite de tamaño del script (ver "Escalabilidad").
- **Que el gateway haga pull** (un timer systemd que consulte `az container list`): requiere darle
  una Managed Identity con permisos de lectura sobre el RG a la VM que está expuesta a internet.
  Ampliar la superficie del único host público del lab para ahorrar un `run-command` es un mal
  intercambio.

### Fuente de verdad

El camino feliz usa el estado local (`yamls/generated/dns/*.hosts`), que es rápido y ya está en
la mano. Pero ese estado se pierde si el operador cambia de máquina, o queda obsoleto si alguien
recrea un contenedor a mano. Por eso `dns-sync --from-azure` reconstruye **todos** los
`team<N>.hosts` y `dmz.hosts` desde `az container list` (una sola llamada) + la IP de `vm-wiki`,
y luego empuja. Es el comando de reparación, y también el que se corre antes del evento para
garantizar que la zona refleja Azure y no la memoria del operador.

## Escalabilidad a ~100 equipos

| Métrica | 20 equipos | 100 equipos | Comentario |
|---|---|---|---|
| Registros A | 80 + 14 + 2 = 96 | 400 + 14 + 2 = 416 | 4 por equipo (`database`, `webapp`, `linux-server`, `xss-bot`) + DMZ (13 ACI + wiki) + infra |
| Líneas del archivo | 96 | 416 | 1 línea = 1 IP + FQDN canónico + alias |
| Tamaño de la zona | ~7 KB | ~30 KB | irrelevante para dnsmasq (lee `/etc/hosts` de cientos de miles de líneas sin despeinarse) |
| Carga del archivo por dnsmasq | ms | ms | inotify, sin reinicio, sin pérdida de cache |
| Regeneración local | <1 s | <1 s | concatenar archivos que ya existen |
| Reconstrucción `--from-azure` | ~5 s | ~15-40 s | **una** llamada `az container list` con 400+ grupos; puede paginar — medir |
| Invocaciones `run-command` para DNS | 1 | 1 | O(1), no O(N) — este es el punto de todo el diseño |
| Latencia de consulta | <1 ms | <1 ms | resolución desde memoria |

El único límite duro que puede aparecer es el **tamaño del script de `az vm run-command
invoke`**: la zona va embebida en base64 dentro del `--scripts`, o sea ~30 KB → ~40 KB de base64
a 100 equipos. Debería pasar holgadamente, pero hay que **medirlo con una zona sintética de 100
equipos antes de asumirlo** (está en el plan de pruebas). Si no pasa, la mitigación es gratis
gracias a `hostsdir`: partir en `teams-001-025`, `teams-026-050`, ... (N/25 invocaciones, todas
en el paso secuencial). Nada más del diseño cambia.

Un segundo detalle de escala, que **no** es del DNS pero conviene anotar porque se ve en la misma
corrida: el Paso 3 de `add_team_range` (peers, secuencial, ~10 s por equipo vía `run-command`)
son ~17 minutos a 100 equipos. El DNS añade 10 s a ese total. Si algún día ese paso se vuelve el
problema, la solución (agrupar M peers por invocación) es la misma idea que ya se aplica aquí, y
convendría hacerla a la vez.

También en la salida de `run-command`: solo se leen los últimos ~4 KB del mensaje. El script
remoto de DNS debe imprimir **un resumen corto** (`OK <n> registros`), nunca la zona.

## Resiliencia: qué pasa cuando el DNS se cae

La pregunta "¿un contenedor que no resuelve su DB queda inutilizable?" tiene una respuesta de una
palabra gracias a la decisión de arriba: **no**, porque su DB no está en un nombre, está en una
IP horneada. Esa es la mitigación principal y es de diseño, no de configuración.

El resto, por escenario:

| Escenario | Efecto real | Mitigación |
|---|---|---|
| dnsmasq muere (crash, OOM) | Los nombres dejan de resolver. Los retos siguen funcionando (env vars = IP). Los contenedores caen al 2º nameserver (`168.63.129.16`) → siguen resolviendo internet, no el lab | Drop-in systemd `Restart=always` / `RestartSec=2` (el `dnsmasq.service` de Ubuntu **no** lo trae) |
| `vm-wg-gateway` se reinicia | ~1-2 min sin VPN **y** sin DNS. Los retos siguen arriba | `systemctl enable dnsmasq`; la zona vive en disco (`/etc/dnsmasq.hosts.d/`), no en memoria; `bind-dynamic` hace que dnsmasq no dependa de que `wg0` exista al arrancar |
| `vm-wg-gateway` se pierde entera | No hay lab desde afuera de todos modos (es el único punto de entrada). Los contenedores dentro de la VNet siguen hablándose por IP | Recrear con `deploy-wg-gateway` + `dns-sync --from-azure` (recompone la zona desde Azure, no desde un backup) |
| Un contenedor arranca con dnsmasq caído | Arranca igual. El pull de imagen no usa el DNS del contenedor. Solo pierde nombres | 2º nameserver + env vars en IP |
| Salida a internet de los contenedores | **Cambia**: hoy van directo a Azure DNS; con `dnsConfig` van a dnsmasq, que reenvía a `168.63.129.16` | `no-resolv` + `server=168.63.129.16` explícito en dnsmasq (obligatorio: sin `no-resolv`, dnsmasq leería `/etc/resolv.conf`, que en Ubuntu 22.04 apunta a `127.0.0.53` — **bucle de resolución consigo mismo**) |
| dnsmasq responde lento / a medias | El resolver de glibc espera el `timeout` antes de probar el 2º nameserver | `options: "ndots:2 timeout:1 attempts:2"` en `dnsConfig` → como mucho ~2 s de penalización, no los 5 s por defecto |
| Un participante deja el túnel arriba y el gateway cae | En Windows/macOS: nada, solo el dominio del lab iba por el túnel (NRPT/matchDomains). En Linux: puede perder **todo** su DNS | Entregar siempre `DNS = 10.200.0.1, sabanacorp.internal` y documentar `wg-quick down` (ver "Split-DNS") |

Nota de seguridad que forma parte de la resiliencia: dnsmasq escucha en `eth0`, y `eth0` es la
NIC a la que Azure NATea la **IP pública** del gateway. Un resolver abierto a internet se
convierte en amplificador de DDoS en cuestión de horas. Dos capas: (a) el NSG `nsg-wg-gateway`
solo permite UDP 51820 desde Internet — **no añadir nunca una regla de 53 desde Internet**; (b)
reglas `INPUT` explícitas que solo aceptan 53 desde `wg0` y desde `10.0.0.0/8` en `eth0`. Hoy la
política de `INPUT` es `ACCEPT` y esas reglas son no-ops, pero dejan la intención escrita y
sobreviven a un futuro `-P INPUT DROP`.

### Rollback

En orden de coste creciente; los dos primeros no tocan ningún contenedor:

1. **Apagar el DNS**: `systemctl stop dnsmasq` en el gateway. Se pierden los nombres. **Ningún
   reto se cae.** Es el botón de pánico durante el evento.
2. **Revertir los clientes**: regenerar los `.conf` con `CLIENT_DNS="1.1.1.1"` (`wg-team-peer
   <N>` por equipo, o un bucle). No requiere tocar el gateway ni los contenedores; solo
   redistribuir archivos.
3. **Revertir los contenedores**: dejar `LAB_DNS_SERVER` vacío (los generadores omiten el bloque
   `dnsConfig`) y redesplegar los equipos afectados con `add-team <N>`. Es lo caro (recrea
   contenedores, cambia IPs) y **solo hace falta si `dnsConfig` resulta activamente dañino** —
   con el 2º nameserver a `168.63.129.16`, un dnsmasq muerto no lo justifica.

Que el rollback sea barato es consecuencia directa de no haber movido las env vars a FQDN. Si se
hiciera la "Fase 5", el paso 3 dejaría de ser opcional y pasaría a ser obligatorio y urgente.

## Cliente WireGuard y split-DNS por sistema operativo

Cambio en `create_wg_peer()`: `CLIENT_DNS="1.1.1.1"` → `CLIENT_DNS="10.200.0.1, ${LAB_DOMAIN}"`,
y `AllowedIPs` del cliente += `10.200.0.1/32`.

El `.conf` resultante para un equipo:

```ini
[Interface]
PrivateKey = ...
Address = 10.200.3.2/32
DNS = 10.200.0.1, sabanacorp.internal

[Peer]
PublicKey = ...
Endpoint = <ip-publica>:51820
AllowedIPs = 10.60.3.0/24, 10.50.0.0/24, 10.51.0.0/24, 10.200.0.1/32
PersistentKeepalive = 25
```

Una sola línea `DNS =` produce **comportamientos distintos por SO**, y hay que documentarlo
porque determina qué se le promete al participante:

**Windows (cliente oficial WireGuard, wireguard-nt) — split-DNS real.**
El segundo valor se traduce en una regla **NRPT** (Name Resolution Policy Table): solo las
consultas que terminan en `sabanacorp.internal` se mandan a `10.200.0.1`; el resto del DNS del
participante sigue yendo a su resolver habitual. Es el comportamiento deseado y el motivo de
incluir el dominio. Si el `.conf` trajera **solo la IP**, el cliente aplicaría ese DNS de forma
global y el participante perdería resolución de internet si el gateway falla.
- Verificación: `Get-DnsClientNrptPolicy`, `Resolve-DnsName webapp.team3.sabanacorp.internal`.
- **Trampa a documentar**: `nslookup` **no respeta NRPT** — habla directo con el servidor por
  defecto del adaptador, así que dirá "no existe" aunque todo esté bien. En Windows se verifica
  con `Resolve-DnsName`, nunca con `nslookup`.

**Linux (`wg-quick` + `resolvconf`/`systemd-resolved`) — no es split-DNS real.**
`wg-quick` interpreta los valores no-IP de `DNS =` como **search domains**, no como reglas de
enrutamiento. En la práctica, con el shim de `resolvconf` de systemd-resolved, `wg0` queda con
`DNS=10.200.0.1` y `Domains=sabanacorp.internal`, y **buena parte (o todo) el tráfico DNS del
equipo pasa por el gateway mientras el túnel está arriba**. Por eso dnsmasq **tiene** que
reenviar hacia arriba: si no, el participante pierde internet por nombre en cuanto se conecta y
el diagnóstico ("me quedé sin internet") va a llegar como incidente de soporte.
- Split real opcional, para quien lo quiera: tras levantar el túnel,
  `sudo resolvectl domain wg0 '~sabanacorp.internal'` (el `~` lo convierte en *routing domain*, y
  solo ese dominio va al túnel).
- **`wg-quick` falla con `resolvconf: command not found`** en instalaciones mínimas y en WSL2 (que
  además regenera `/etc/resolv.conf` por su cuenta). Solución documentada:
  `sudo apt install openresolv`; alternativa sin tocar nada: borrar la línea `DNS =` del `.conf` y
  usar `dig @10.200.0.1 <nombre>` / `curl --resolve` cuando haga falta.

**macOS.**
- App oficial (App Store): usa `NEDNSSettings` con *match domains* → comportamiento split
  equivalente al de Windows.
- `wg-quick` de Homebrew: usa `networksetup -setdnsservers` sobre todos los servicios de red →
  DNS global mientras el túnel está arriba, restaurado al bajarlo. Igual que Linux.

**Android/iOS** (app oficial): soportan `DNS = ip, dominio` con match domains, como Windows. No
es un caso previsto para participantes, se menciona por completitud.

### Qué se le entrega al participante

El `.conf` no basta como entregable. Junto a él se genera un
`yamls/generated/wg-clients/team<N>-README.md` (nueva plantilla) con:

1. Cómo importar el `.conf` en su SO.
2. **La tabla de FQDN de su propio equipo** (los 4) + los de la DMZ. Es la "hoja de servicios de
   Sabana Corp" — reemplaza a la lista de IPs, y es material de juego, no solo documentación.
3. El comando de verificación de su SO (`Resolve-DnsName` en Windows, `getent hosts` /
   `resolvectl query` en Linux, `dscacheutil -q host -a name` en macOS).
4. La nota de `openresolv` para Linux/WSL.
5. Una línea explícita: *"que un nombre resuelva no significa que puedas alcanzarlo"* — evita
   tickets de soporte del tipo "el DNS está roto" cuando lo que pasa es que están intentando
   entrar a otro equipo.

## Aislamiento: resolver no es alcanzar

El control de acceso **no cambia en absoluto**: sigue siendo `iptables` en `vm-wg-gateway`, una
regla `FORWARD` por peer y por CIDR permitido con política `DROP`, validada end-to-end el
2026-08-08 (incluido un intento real de bypass editando el `AllowedIPs` del cliente). El DNS es
un servicio de nombres, no una frontera.

**Recomendación: zona plana, sin split-horizon. Todo el mundo resuelve todo (excepto
`snet-mgmt`, que directamente no se publica).**

Motivos, en orden de peso:

1. **Es sabor de CTF, no una fuga.** Descubrir que existe `webapp.team7.sabanacorp.internal`, o
   que un `dig -x 10.50.0.9` devuelve `printer-01.dmz`, es reconocimiento — exactamente lo que un
   pentester hace en una red corporativa real, y exactamente el tipo de cosa que la DMZ con
   decoys ya está diseñada para premiar. Además el esquema es adivinable en tres segundos
   (`team<N>`), así que ocultarlo no oculta nada.
2. **El límite ya existe y ya está probado.** Un equipo que resuelve `webapp.team7` y hace `curl`
   se come un timeout en el `DROP` del gateway. Ese contrato ("resuelvo, no alcanzo") es fácil de
   explicar, fácil de probar (está en el plan de pruebas como test negativo) y no depende de que
   el DNS se comporte.
3. **dnsmasq no tiene vistas.** Implementar split-horizon exigiría una instancia por equipo
   (100 procesos, 100 IPs de escucha o 100 puertos, y una regla de enrutamiento por peer), o
   cambiar a CoreDNS con el plugin `view`. Es multiplicar por 100 la complejidad del componente
   que —si falla— apaga los nombres de todo el evento, para proteger información que el
   participante puede adivinar. Mal intercambio.
4. **La complejidad en la capa de nombres es lo que produce caídas.** Un archivo, un proceso, una
   verdad. Poder decir "`cat /etc/dnsmasq.hosts.d/teams`" y ver la realidad completa vale más
   durante el evento que cualquier refinamiento.

La única restricción que sí se aplica es de publicación, no de resolución: **`snet-mgmt` no
entra en la zona** (ver "Esquema de nombres").

## Cambios archivo por archivo

### `yamls/wg-gateway/cloud-init.yaml`

- `packages:` += `dnsmasq`.
- `write_files:` += `/etc/dnsmasq.d/00-lab.conf`:

```
# Escucha solo en las interfaces del lab. bind-dynamic (no bind-interfaces): tolera que wg0
# aparezca/desaparezca y evita chocar con el stub de systemd-resolved en 127.0.0.53:53.
bind-dynamic
interface=wg0
interface=eth0

# Upstream explicito. no-resolv es OBLIGATORIO: sin el, dnsmasq leeria /etc/resolv.conf, que en
# Ubuntu 22.04 apunta a 127.0.0.53 (systemd-resolved) -> bucle de resolucion consigo mismo.
no-resolv
server=168.63.129.16

# La zona del lab nunca se reenvia hacia arriba: Azure DNS no la conoce, y sin esto cada nombre
# inexistente del lab se va a internet y tarda.
local=/sabanacorp.internal/
domain=sabanacorp.internal
expand-hosts
domain-needed
bogus-priv

# Registros del lab: formato /etc/hosts, un archivo por bloque, recargados por inotify (sin
# SIGHUP y sin reiniciar el servicio -- SIGHUP no relee /etc/dnsmasq.d/*.conf, hostsdir si).
hostsdir=/etc/dnsmasq.hosts.d

# TTL corto: si un contenedor se recrea con otra IP, la correccion propaga en segundos.
local-ttl=10
cache-size=1000
log-facility=/var/log/dnsmasq.log
#log-queries   # activar solo para depurar; en el evento genera mucho ruido
```

- `write_files:` += `/etc/dnsmasq.hosts.d/.keep` (el directorio **tiene que existir** antes de
  que dnsmasq arranque: si `hostsdir` apunta a algo inexistente, dnsmasq falla al iniciar).
- `write_files:` += `/etc/systemd/system/dnsmasq.service.d/10-restart.conf` con
  `[Service]\nRestart=always\nRestartSec=2`.
- `runcmd:` += reglas `INPUT` para 53 (documentan la intención; no-ops mientras `INPUT` sea
  `ACCEPT`):
  `iptables -A INPUT -i wg0 -p udp --dport 53 -j ACCEPT` (+ tcp), y
  `iptables -A INPUT -i eth0 -s 10.0.0.0/8 -p udp --dport 53 -j ACCEPT` (+ tcp), antes del
  `netfilter-persistent save` que ya existe.
- `runcmd:` += `systemctl enable --now dnsmasq`.
- Añadir al comentario de cabecera la nota de por qué `no-resolv`.

### `yamls/wg-gateway/remote/apply-dns.sh.tpl` (nuevo)

Mismo patrón que `add-peer.sh.tpl`: plantilla `envsubst` con lista blanca de variables
(`${ZONE_NAME}`, `${ZONE_B64}`), resuelta **localmente** y mandada completa como un solo string a
`az vm run-command invoke`. Hace:

1. `echo "${ZONE_B64}" | base64 -d > /tmp/lab.hosts.$$`
2. Validación mínima antes de instalar (que no esté vacío y que cada línea empiece por IP) — un
   archivo corrupto no debe llegar a `hostsdir`.
3. Instalación **atómica**: `install -m 644 /tmp/lab.hosts.$$ /etc/dnsmasq.hosts.d/${ZONE_NAME}`
   (o `mv`), nunca un `cat >` directo sobre el destino.
4. Espera corta + comprobación de que dnsmasq responde: `dig +short @127.0.0.1 <un-nombre>`.
   Si no responde, `systemctl restart dnsmasq` como red de seguridad y reintento.
5. Salida corta y parseable (`OK registros=<n>`), porque `run-command` trunca el mensaje.

Idempotente por construcción: reemplaza el archivo completo, no edita.

### `yamls/generate-dns-hosts.sh` (nuevo)

Sigue la convención de los otros generadores (`set -euo pipefail`, validación de entorno, escribe
en `generated/`, imprime lo que generó). Dos modos:

- **Por equipo** (`generate-dns-hosts.sh team <N> <ip_db> <ip_webapp> <ip_linux> <ip_bot>`) →
  escribe `generated/dns/team<N>.hosts`. Lo llama `deploy_team_workload()` con las IPs que ya
  tiene en la mano; sin llamadas a Azure, seguro en paralelo.
- **DMZ** (`generate-dns-hosts.sh dmz`) → escribe `generated/dns/dmz.hosts` + `infra.hosts`,
  leyendo `az container list` (los 13 de DMZ) y `az vm list-ip-addresses -n vm-wiki`.
- **Reconstrucción** (`generate-dns-hosts.sh all-from-azure`) → regenera **todos** los
  `team<N>.hosts` + `dmz.hosts` con una sola `az container list`, derivando equipo y servicio del
  nombre del container group.

Contiene la tabla de alias narrativos (array asociativo) y la regla de derivación mecánica. Salida
de ejemplo:

```
# generado por yamls/generate-dns-hosts.sh -- no editar a mano
10.50.0.6   filesrv.dmz.sabanacorp.internal filesrv.dmz files.dmz.sabanacorp.internal
10.51.0.4   wiki.dmz.sabanacorp.internal wiki.dmz wiki-int.dmz.sabanacorp.internal
10.50.0.9   printer-01.dmz.sabanacorp.internal printer.dmz.sabanacorp.internal
10.60.3.4   database.team3.sabanacorp.internal db.team3.sabanacorp.internal
10.60.3.5   webapp.team3.sabanacorp.internal helpdesk.team3.sabanacorp.internal
10.60.3.6   linux-server.team3.sabanacorp.internal pivot.team3.sabanacorp.internal
10.60.3.7   xss-bot.team3.sabanacorp.internal bot.team3.sabanacorp.internal
10.200.0.1  dns.sabanacorp.internal gw.sabanacorp.internal
```

Añadir `generated/dns/` al `.gitignore` de `yamls/` — ya cubierto por `generated/`.

### `yamls/templates/team-*.yaml.tpl` (los 4) y `dmz-*.yaml.tpl` (los 14)

Bloque nuevo bajo `properties:`, al mismo nivel que `containers`/`osType`/`subnetIds`:

```yaml
  # DNSCONFIG-BEGIN -- lo elimina el generador si LAB_DNS_SERVER esta vacio (lab sin gateway).
  # 2o nameserver a proposito: si dnsmasq no responde, el contenedor sigue resolviendo internet
  # via Azure DNS. Los nombres del lab dejan de resolver, pero ningun reto se cae porque
  # DB_HOST/WEBAPP_BASE_URL siguen siendo IPs (ver docs/plans/internal-dns.md).
  dnsConfig:
    nameServers:
      - "${LAB_DNS_SERVER}"
      - "168.63.129.16"
    searchDomains: "team${TEAM}.${LAB_DOMAIN} dmz.${LAB_DOMAIN} ${LAB_DOMAIN}"
    options: "ndots:2 timeout:1 attempts:2"
  # DNSCONFIG-END
```

(en las plantillas `dmz-*`, el `searchDomains` es `"dmz.${LAB_DOMAIN} ${LAB_DOMAIN}"`).

Efecto secundario deseable de `searchDomains`: dentro de un contenedor de `team3`, `curl
http://webapp` resuelve a **su propio** webapp, y `curl http://filesrv` a la DMZ. Para el
participante que acaba de pivotar a `linux-server`, eso es la diferencia entre "una red" y "una
lista de IPs".

**Los `<DATABASE_IP>` / `<WEBAPP_IP>` se quedan como están.** No se tocan (ver "El huevo y la
gallina").

### `yamls/generate-team.sh` y `yamls/generate-dmz.sh`

- Añadir `LAB_DOMAIN` y `LAB_DNS_SERVER` a los `export` y a la lista blanca `VARS` de `envsubst`.
- Tras el `envsubst`, si `LAB_DNS_SERVER` está vacío: `sed -i '/DNSCONFIG-BEGIN/,/DNSCONFIG-END/d'`
  sobre el archivo generado. `envsubst` no sabe de condicionales; el bloque con centinelas es la
  forma más simple de tener el "sin gateway" funcionando. Esto es lo que mantiene vivo el flujo
  `./lab-azure.sh test [N]` (que a propósito no despliega gateway).
- Actualizar el comentario de cabecera de `generate-team.sh` (menciona explícitamente qué queda
  sin resolver y por qué).

### `yamls/templates/wg-client.conf.tpl`

- La línea `DNS = ${CLIENT_DNS}` no cambia de forma, cambia de contenido (lo llena
  `create_wg_peer`).
- Añadir al bloque de comentarios de cabecera la explicación de split-DNS por SO (resumen de 4-5
  líneas + puntero a este documento), y la nota de que `10.200.0.1/32` en `AllowedIPs` es lo que
  permite que el DNS del lab funcione.

### `yamls/templates/wg-client-readme.md.tpl` (nuevo) y `yamls/generate-wg-client.sh`

Nueva plantilla con el entregable del participante (ver "Qué se le entrega"). `generate-wg-client.sh`
renderiza los dos archivos (`.conf` + `README.md`) con las mismas variables + `LAB_DOMAIN` y el
número de equipo.

### `yamls/templates/wiki-vm-compose.yml.tpl`

`APP_URL: "http://wiki-int.empresa.local"` → `"http://wiki.dmz.${LAB_DOMAIN}"`. Es un cambio real
de comportamiento, no cosmético: BookStack construye sus enlaces absolutos con `APP_URL`, así que
hoy cualquier redirección o enlace generado apunta a un nombre que no resuelve en ninguna parte.
`generate-wiki-vm.sh` tiene que exportar `LAB_DOMAIN`.

### `lab-azure.sh`

Variables nuevas (arriba, junto a `RG`/`VNET`):
```bash
LAB_DOMAIN="${LAB_DOMAIN:-sabanacorp.internal}"
WG_GW_PRIVATE_IP="10.10.0.4"   # estatica: la fija deploy_wg_gateway; ver docs/plans/internal-dns.md
WG_GW_TUNNEL_IP="10.200.0.1"   # la fija yamls/wg-gateway/cloud-init.yaml
DNS_DIR="${YAMLS_DIR}/generated/dns"
```

Funciones **nuevas**:
- `lab_dns_server()` — devuelve `WG_GW_PRIVATE_IP` si `vm-wg-gateway` existe, cadena vacía si no.
  Es lo que decide si las plantillas llevan `dnsConfig`.
- `sync_lab_dns()` — concatena `${DNS_DIR}/*.hosts`, renderiza `apply-dns.sh.tpl` con `envsubst`,
  lo manda en **una** invocación de `run-command`, valida la salida. Guardada y no bloqueante
  (mismo espíritu que `create_wg_team_peer`): si `vm-wg-gateway` no existe, avisa y sigue — un
  lab sin gateway tiene que seguir desplegándose igual.
- `rebuild_lab_dns_from_azure()` — llama a `generate-dns-hosts.sh all-from-azure` + `sync_lab_dns`.

Funciones **modificadas**:
- `deploy_wg_gateway()` — `--private-ip-address 10.10.0.4` en el `az vm create`; el bucle de
  espera pasa a comprobar también `systemctl is-active dnsmasq`; al final, `sync_lab_dns` (para
  que un gateway recreado recupere la zona sin pasos manuales).
- `create_wg_peer()` — `CLIENT_DNS="${WG_GW_TUNNEL_IP}, ${LAB_DOMAIN}"`; y separar las dos listas
  de CIDRs: `CLIENT_ALLOWED_IPS` = `allowed_cidrs` + `${WG_GW_TUNNEL_IP}/32`, mientras que lo que
  se le pasa a `add-peer.sh.tpl` (las reglas `FORWARD`) sigue siendo solo `allowed_cidrs`.
- `create_wg_team_peer()` — sin cambios en los CIDRs permitidos (el `/32` del DNS lo añade
  `create_wg_peer`).
- `deploy_team_workload()` — exporta `LAB_DOMAIN` y `LAB_DNS_SERVER` al llamar a
  `generate-team.sh`; y al final, tras desplegar los 4, llama a `generate-dns-hosts.sh team <N>
  ...` con las IPs que ya tiene. **Solo escritura local** — nada de `run-command` aquí, es la fase
  paralela.
  (Requiere capturar también las IPs de `linux-server` y `xss-bot`, que hoy se descartan con
  `>/dev/null`.)
- `deploy_team()` — `sync_lab_dns` después de `create_wg_team_peer`.
- `deploy_dmz()` — exporta las variables al generador; al final, `generate-dns-hosts.sh dmz` +
  `sync_lab_dns`.
- `create_wiki_vm()` — añade `vm-wiki` a `infra`/`dmz.hosts` + `sync_lab_dns` (es el registro de
  `wiki.dmz`, que vive en una VM y no sale de `az container list`).
- `add_team_range()` — **Paso 2.5 nuevo, secuencial, entre workloads y peers**: un solo
  `sync_lab_dns`. Actualizar el comentario largo de la función para explicar por qué el DNS es
  O(1) y por qué va en un paso secuencial (RunCommand es de un solo hilo por VM).
- `status()` — en la sección "Gateway WireGuard", añadir estado de dnsmasq y número de registros:
  `systemctl is-active dnsmasq; wc -l /etc/dnsmasq.hosts.d/*` vía `run-command` (una sola
  invocación, aprovechando la que ya hace `wg show wg0`).
- Entrypoint: subcomandos nuevos `dns-sync` (con flag `--from-azure`) y `dns-check <fqdn>`
  (resuelve desde el gateway y compara con la IP real de Azure — el chequeo que se corre antes de
  abrir el evento). Actualizar el `usage` y la cabecera de comentarios del script.

### `CLAUDE.md`

- Comandos: `dns-sync`, `dns-check`.
- Nueva sección "Decisión de diseño: DNS interno con dnsmasq en el gateway", con el resumen de
  este documento: dominio `.internal` (y por qué no `.local`), zona plana sin split-horizon, y
  —lo más importante para quien venga después— **que las env vars siguen siendo IPs a propósito**.
  Sin esa frase, el siguiente que toque `team-webapp.yaml.tpl` va a "arreglar" el `<DATABASE_IP>`
  poniendo un FQDN y va a convertir el DNS en dependencia dura de los retos.
- Generalizar la sección de paralelismo: la regla no es "los peers son secuenciales", es **"toda
  escritura sobre `vm-wg-gateway` va en un paso secuencial"**, porque `az vm run-command invoke`
  es de un solo hilo por VM.
- "Arquitectura de red objetivo": `snet-wg-gateway` pasa a ser también el DNS del lab, con IP
  privada estática `10.10.0.4`.

### `yamls/README.md`

- Sección de dnsmasq/hostsdir y del flujo `generate-dns-hosts.sh` → `sync_lab_dns`.
- Actualizar "Orden de despliegue y resolución de IPs": sigue vigente tal cual, y **explicar por
  qué sigue vigente aun con DNS** (es la pregunta que se va a hacer todo el que lea las dos
  secciones seguidas).
- "Pendiente / gaps conocidos": añadir el estado del DNS.

### `docs/plans/network-segmentation-nsgs.md`

Nota nueva bajo la matriz: si algún día se aplican los NSGs, **`snet-team*` y `snet-dmz-*` tienen
que poder alcanzar `snet-wg-gateway` en UDP/TCP 53**. La matriz actual deja esa columna en blanco
("fuera de alcance"), lo que hoy es correcto pero se volvería un corte silencioso del DNS de
todos los contenedores. Mismo aviso para `nsg-wg-gateway`: su comentario actual dice que es
"deliberadamente más restrictivo que el default"; si alguien materializa esa intención con un
`DenyVnetInBound`, hay que añadir antes una regla `allow-dns-inbound` (53 desde `VirtualNetwork`).

### `docs/plans/observability-monitoring.md`

- La alerta `DerivaDeIP` **sigue siendo necesaria** (las env vars siguen en IP) y ahora tiene una
  hermana: comparar el registro DNS contra la IP real de Azure (que es lo que hace `dns-check`).
- Alerta nueva `DnsCaido`: sonda TCP/UDP 53 contra `10.10.0.4`. Severidad media, no crítica —
  ningún reto se cae, pero los nombres dejan de funcionar.

### `README.md` (raíz)

Actualizar "Estado actual" y el flujo de uso con los subcomandos nuevos.

## Fases de implementación

Cada fase es verificable por sí sola y **reversible sin tocar la anterior**. El orden está elegido
para que el riesgo crezca monótonamente: se toca el gateway, luego los clientes (rollback =
regenerar un archivo), y solo al final los contenedores (rollback = redesplegar).

**Fase 0 — Verificar supuestos (medio día, sin escribir código de producción).**
Cuatro incógnitas que si salen mal cambian el diseño, así que se prueban antes:
1. `dnsConfig` se aplica de verdad en un container group en VNet → desplegar **un** contenedor de
   prueba con `dnsConfig` apuntando a `1.1.1.1` y `az container exec ... cat /etc/resolv.conf`.
2. Que el pull de imagen no depende del `dnsConfig` del contenedor → mismo contenedor con un
   `nameServers` que no existe; tiene que arrancar igual.
3. `az container list --query "[].{n:name,ip:ipAddress.ip}"` devuelve la IP (el repo ya sabe que
   `instanceView` **no** viene poblado en `list`; `ipAddress` es otra propiedad, pero hay que
   confirmarlo — de eso depende `--from-azure`).
4. Dos `az vm run-command invoke` concurrentes contra la misma VM: confirmar que fallan o se
   serializan. Confirma la regla de "escrituras secuenciales" y cierra el riesgo de raza.

**Fase 1 — dnsmasq en el gateway, sin clientes ni contenedores.**
`cloud-init.yaml`, `apply-dns.sh.tpl`, `generate-dns-hosts.sh`, `sync_lab_dns()`, subcomando
`dns-sync`. Verificable **enteramente desde el gateway** (`dig @127.0.0.1`). Nadie más lo usa
todavía; impacto en el lab existente: cero. Requiere recrear `vm-wg-gateway` (o aplicar el
cloud-init a mano por `run-command` en la VM viva, que es lo que conviene si ya hay equipos con
túnel entregado — recrear la VM invalida todos los `.conf`).

**Fase 2 — Clientes VPN.**
`CLIENT_DNS`, `10.200.0.1/32` en `AllowedIPs`, `wg-client.conf.tpl`, README del participante.
Verificable desde el PC del operador con `admin.conf` y con `team1.conf`, en Linux y en Windows.
Rollback: regenerar `.conf`. No toca ningún contenedor.

**Fase 3 — `dnsConfig` en los contenedores.**
Plantillas + generadores + `lab_dns_server()`. Probar primero con **un solo equipo nuevo**
(`add-team 3`) antes de tocar nada más, incluyendo la prueba con dnsmasq apagado a propósito.

**Fase 4 — Integración en el ciclo de vida.**
`deploy_team_workload`, `deploy_dmz`, `add_team_range` (Paso 2.5), `create_wiki_vm`, `status`,
`dns-check`. Es donde se valida el comportamiento con paralelismo real (`add-team-range 4 8 4`).

**Fase 5 — Documentación.**
`CLAUDE.md`, `yamls/README.md`, `README.md`, notas cruzadas en los otros dos planes. Va al final
a propósito: se documenta lo que se midió, no lo que se diseñó.

**Fase 6 — NO se ejecuta para el evento: env vars a FQDN.**
Queda escrita aquí para que la decisión sea explícita y no se tome por accidente. Reevaluar solo
cuando exista el subcomando `restore` de `docs/plans/observability-monitoring.md`, que es donde el
beneficio (no redesplegar dependientes) empieza a pagar el riesgo.

## Plan de pruebas

### Desde el gateway (Fase 1)

```bash
az vm run-command invoke -g rg-ctf-semana-ingenieria-test -n vm-wg-gateway --command-id RunShellScript \
  --scripts "systemctl is-active dnsmasq; ss -lunp | grep :53; dnsmasq --test; \
             dig +short @127.0.0.1 webapp.team1.sabanacorp.internal; \
             dig +short @127.0.0.1 filesrv.dmz.sabanacorp.internal; \
             dig +short @127.0.0.1 -x 10.50.0.6; \
             dig +short @127.0.0.1 www.google.com" \
  --query "value[0].message" -o tsv | sed -n '/\[stdout\]/,/\[stderr\]/{//!p}'
```
Se valida a la vez: proceso vivo, escuchando donde debe (`wg0`/`eth0`, **no** en `127.0.0.53`),
config sintácticamente correcta, zona del lab, PTR, y **reenvío a internet** (si esta última
falla, hay un bucle con systemd-resolved o falta `no-resolv`).

### Desde un contenedor (Fase 3)

```bash
az container exec -g rg-ctf-semana-ingenieria-test -n team3-linux-server --exec-command "/bin/sh"
# dentro:
cat /etc/resolv.conf          # nameserver 10.10.0.4 + 168.63.129.16 + search team3... dmz... 
getent hosts webapp.team3.sabanacorp.internal
getent hosts filesrv          # search domain: tiene que resolver a filesrv.dmz.<dom>
getent hosts webapp           # tiene que resolver a SU webapp, no al de otro equipo
```
`getent hosts` en vez de `dig`/`nslookup`: las imágenes de reto no traen `dnsutils`, pero sí
glibc. Verificar `/etc/resolv.conf` es lo que prueba que `dnsConfig` se aplicó de verdad.

### Desde el PC por VPN — Linux (Fase 2)

```bash
sudo wg-quick up ./yamls/generated/wg-clients/team1.conf
resolvectl status wg0                    # DNS Servers: 10.200.0.1 / Domains: sabanacorp.internal
getent hosts webapp.team1.sabanacorp.internal
dig @10.200.0.1 webapp.team1.sabanacorp.internal   # prueba directa, sin pasar por el stack del SO
curl -s -o /dev/null -w '%{http_code}\n' http://webapp.team1.sabanacorp.internal   # 302
curl -s -o /dev/null -w '%{http_code}\n' http://filesrv.dmz.sabanacorp.internal:8080  # 200
sudo wg-quick down ./yamls/generated/wg-clients/team1.conf
getent hosts webapp.team1.sabanacorp.internal      # ahora NO debe resolver (DNS restaurado)
```

### Desde el PC por VPN — Windows (Fase 2)

```powershell
Get-DnsClientNrptPolicy | Where-Object {$_.Namespace -like "*sabanacorp*"}   # regla presente
Resolve-DnsName webapp.team1.sabanacorp.internal    # NO usar nslookup: ignora NRPT
Invoke-WebRequest http://webapp.team1.sabanacorp.internal -UseBasicParsing
Resolve-DnsName www.google.com                      # sigue resolviendo por su DNS normal
```
Última línea = la prueba de que el split-DNS **es split** y no un secuestro global.

### Prueba negativa clave: resolver ≠ alcanzar

```bash
sudo wg-quick up ./yamls/generated/wg-clients/team1.conf
getent hosts webapp.team2.sabanacorp.internal            # SÍ resuelve (por diseño)
curl -s --max-time 5 http://webapp.team2.sabanacorp.internal   # DEBE dar timeout
# confirmar en el gateway que subió el contador de DROP, igual que en la validación de 2026-08-08:
az vm run-command invoke ... --scripts "iptables -L FORWARD -v -n"
```
Esta es la prueba que documenta el modelo de seguridad; sin ella, "el DNS lo muestra todo" suena a
fuga en vez de a decisión.

### Resiliencia (Fase 3, antes de dar el plan por bueno)

```bash
# 1. dnsmasq muere -> los retos siguen vivos
az vm run-command invoke ... --scripts "systemctl stop dnsmasq"
curl http://<ip-webapp-team1>/          # 302: el reto sigue funcionando por IP
az container exec -n team1-webapp ...   # webapp sigue hablando con su DB (IP horneada)
az vm run-command invoke ... --scripts "systemctl start dnsmasq"

# 2. Restart automatico
az vm run-command invoke ... --scripts "pkill -9 dnsmasq; sleep 5; systemctl is-active dnsmasq"  # active

# 3. Reboot del gateway (nunca se ha probado un reboot real -- riesgo abierto en
#    wireguard-vpn-gateway.md; esta es la ocasion de cerrarlo para wg0 y dnsmasq a la vez)
az vm restart -g ... -n vm-wg-gateway
# tras arrancar: wg0 activo, dnsmasq activo, zona intacta, tunel reconecta

# 4. Contenedor nuevo con dnsmasq caido
az vm run-command invoke ... --scripts "systemctl stop dnsmasq"
./lab-azure.sh add-team 9      # debe completar (con warning), los 4 contenedores Running
```

### Escala (antes de confiar en 100 equipos)

Generar una zona sintética de 100 equipos (416 registros) sin desplegar nada, empujarla y medir:
tamaño del script de `run-command` (¿pasa el límite?), tiempo del push, tiempo de carga de
dnsmasq, latencia de `dig`. Si el push no pasa, partir en bloques de 25 en `hostsdir`.

### End-to-end del evento

`add-team-range 4 8 4` (paralelo real) → `dns-check` de los 20 nombres resultantes → conectarse
con `team5.conf` desde Windows y desde Linux → resolver y alcanzar los 4 propios + los de DMZ →
resolver pero **no** alcanzar los de `team6`.

## Riesgos y mitigación

| # | Riesgo | Impacto | Mitigación |
|---|---|---|---|
| 1 | `dnsConfig` no se comporta como se espera en ACI+VNet | Fase 3 inviable; el DNS solo sirviría a clientes VPN (que ya es el 80% del valor) | Fase 0 lo prueba con un contenedor antes de tocar 18 plantillas |
| 2 | La IP privada del gateway cambia al recrear la VM | **Todos** los contenedores apuntan a un DNS inexistente | `--private-ip-address 10.10.0.4` estática + constante en `lab-azure.sh` |
| 3 | El cliente de equipo no puede hablar con `10.200.0.1` | El DNS "no funciona" solo para equipos, y el síntoma (silencio, sin log en el gateway) es engañoso porque el descarte ocurre en el kernel del propio cliente | `10.200.0.1/32` en `AllowedIPs`; probado explícitamente en Fase 2 |
| 4 | Bucle dnsmasq ↔ systemd-resolved | dnsmasq no resuelve nada externo; timeouts en cascada | `no-resolv` + `server=168.63.129.16`; probado con `dig www.google.com` |
| 5 | dnsmasq no arranca por conflicto de puerto 53 | Fase 1 bloqueada | `bind-dynamic` + `interface=` explícito; verificar con `ss -lunp` |
| 6 | `hostsdir` inexistente al arrancar | dnsmasq no inicia | Crear el directorio en `write_files` (`.keep`) |
| 7 | Escritura no atómica → inotify lee un archivo a medias | Zona corrupta, nombres que desaparecen aleatoriamente | `install`/`mv` desde `/tmp`, nunca `cat >` sobre el destino |
| 8 | Dos escrituras concurrentes al gateway | Conflicto de RunCommand; fallo de `add-team-range` | Todas las escrituras en pasos secuenciales; `flock` local |
| 9 | El script de `run-command` supera el límite de tamaño a 100 equipos | `dns-sync` falla justo cuando más equipos hay | Medirlo en la prueba de escala; partir en bloques de 25 (gratis con `hostsdir`) |
| 10 | `.local` y mDNS | Resolución intermitente en macOS/Linux, imposible de diagnosticar en caliente | Dominio `.internal` |
| 11 | Linux/WSL sin `openresolv` → `wg-quick` falla | El participante no puede ni levantar el túnel | Documentado en el README del cliente + fallback (borrar la línea `DNS =`) |
| 12 | Participante Linux pierde todo su DNS si el gateway cae con el túnel arriba | Soporte durante el evento | dnsmasq reenvía a internet; documentar `wg-quick down`; `resolvectl domain wg0 '~dominio'` como split opcional |
| 13 | Resolver abierto a internet (amplificación DDoS) | El gateway se convierte en participante de un ataque; posible bloqueo de Azure | NSG solo 51820 desde Internet + `INPUT` de 53 limitado a `wg0` y `10.0.0.0/8` |
| 14 | Alguien "arregla" `<DATABASE_IP>` poniendo un FQDN | El DNS pasa a ser dependencia dura de los retos sin que nadie lo decida | Comentario explícito en las plantillas + sección en `CLAUDE.md` |
| 15 | La zona local queda obsoleta respecto a Azure | Nombres que apuntan a IPs muertas; peor que no tener nombres | `dns-sync --from-azure` + `dns-check` en el checklist previo al evento |
| 16 | Recrear `vm-wg-gateway` para aplicar el cloud-init invalida todos los `.conf` entregados | Todos los equipos se quedan fuera | Si ya hay túneles entregados, aplicar la config de dnsmasq por `run-command` sobre la VM viva en vez de recrearla; el cloud-init queda para el próximo gateway desde cero (mismo patrón que se usó al corregir el bug de `RELATED,ESTABLISHED`) |

## Criterios de aceptación

1. `dig @127.0.0.1` en el gateway resuelve un servicio de equipo, uno de DMZ, un PTR y un nombre
   de internet.
2. Un contenedor recién desplegado muestra `10.10.0.4` y `168.63.129.16` en `/etc/resolv.conf`, y
   `getent hosts webapp` resuelve a **su propio** webapp vía search domain.
3. Desde el PC con `team1.conf`: `curl http://webapp.team1.sabanacorp.internal` devuelve 302 y
   `http://filesrv.dmz.sabanacorp.internal:8080` devuelve 200, en Linux **y** en Windows.
4. En Windows, `Get-DnsClientNrptPolicy` muestra la regla del dominio del lab y `Resolve-DnsName
   www.google.com` sigue usando el DNS del participante (split-DNS confirmado).
5. `webapp.team2...` resuelve desde `team1.conf` pero el `curl` da timeout y el contador de `DROP`
   del gateway sube.
6. Con `systemctl stop dnsmasq`: `curl` por IP a webapp sigue en 302, `webapp` sigue hablando con
   su DB, y `add-team <N>` completa sin error (con warning).
7. Tras `az vm restart` del gateway: `wg0` y dnsmasq activos, zona intacta, túnel reconecta.
8. `add-team-range 4 8 4` completa sin errores de RunCommand y los 20 nombres resultantes pasan
   `dns-check`.
9. Una zona sintética de 100 equipos (416 registros) se empuja en una sola invocación y `dig`
   responde en <5 ms.
10. `./lab-azure.sh test 1` (sin gateway) sigue funcionando: los YAML generados **no** llevan
    bloque `dnsConfig`.
11. `status` muestra el estado de dnsmasq y el número de registros.
12. `CLAUDE.md` deja escrito que las env vars siguen en IP **y por qué**.

## Abierto / no decidido

- **DNSSEC / DoT hacia el upstream**: innecesario (el upstream es la plataforma de Azure por una
  dirección link-local). No implementar.
- **Registros SRV / wildcards** (`*.team3` → webapp): tentador para el sabor de "empresa", pero
  facilita fingerprinting accidental y no lo pidió nadie. Fuera por ahora.
- **`log-queries` durante el evento**: sería una fuente de telemetría gratis sobre qué está
  enumerando cada equipo (interesante para el staff y para el scoreboard), pero genera mucho ruido
  y hay que decidir rotación de log. Encaja mejor como entrada de
  `docs/plans/observability-monitoring.md` que aquí.
- **Nombres para CTFd / Provisioner / Monitor**: se definirán cuando existan. La regla de
  derivación ya los cubre si viven en la DMZ; si viven en `snet-mgmt`, no se publican (ver
  "Esquema de nombres") — salvo CTFd, que probablemente sí necesite nombre porque los
  participantes tienen que llegar a él. Decidir cuando se implemente.
- **DHCP/registro dinámico**: dnsmasq también hace DHCP, pero en Azure el DHCP es de la
  plataforma. No aplica; se menciona solo para que nadie lo intente.
- **Segundo resolver para alta disponibilidad**: no vale la pena. Si `vm-wg-gateway` cae, no hay
  entrada al lab; un segundo DNS resolvería nombres que nadie puede alcanzar.

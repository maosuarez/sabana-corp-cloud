# Plan: mover dmz-wiki + dmz-wiki-db a una VM con docker-compose

## Estado

**Validado end-to-end 2026-08-08.** Cuota desbloqueada tras upgrade a Pay-As-You-Go
(`StandardDsv7Family`, 10 vCPUs en eastus2). `./lab-azure.sh deploy-wiki-vm` corrido con
éxito: `vm-wiki` (`Standard_D2s_v7`, `snet-dmz-vm`, IP `10.51.0.4`) desplegada, cloud-init
instaló Docker, `docker compose up -d` levantó `wiki` (Up, sin restart) y `wiki-db`
(healthy) — s6-overlay arranca bien con PID 1 real, confirmando el diagnóstico de por qué
fallaba en ACI. `curl http://localhost` en la VM devuelve 302 (redirect a `/login`,
comportamiento normal de BookStack). Riesgo pendiente de la sección anterior también
verificado: routing cross-subnet `snet-dmz-vm` → `snet-dmz-shared` funciona sin NSGs
(ping y `curl` a `dmz-filesrv:8080` desde la VM devuelven 200/OK).

`lab-azure.sh:deploy_dmz()` ya no despliega `dmz-wiki`/`dmz-wiki-db` como contenedores
ACI (se quitaron del loop de despliegue) — el wiki vive solo en `vm-wiki` ahora.

Pendiente real: `az vm run-command invoke` sí funcionó (no hubo que caer a SSH +
`nsg-jumpbox`). Falta solo validar el wiki desde un navegador real (vía el flujo VPN, aún
sin implementar) y decidir si la VM se apaga fuera de horarios de prueba
(`az vm deallocate`) para no acumular costo.

Histórico (bloqueo ya resuelto, se deja para contexto):

Scripts escritos (`yamls/templates/wiki-vm-compose.yml.tpl`, `yamls/generate-wiki-vm.sh`,
`yamls/wiki-vm/cloud-init.yaml`, `lab-azure.sh deploy-wiki-vm`) pero **NO PROBADOS ni una
vez** — el bloqueo de cuota (ver abajo) resultó ser más duro de lo que parecía al escribir
la primera versión de este documento: no es que falte pedir el aumento, es que **Azure for
Students no es elegible para pedir aumento de quota de VM en absoluto** (confirmado
2026-08-02, ni self-service ni por ticket de soporte — el formulario de Azure lo dice
explícito: "Your subscription isn't eligible for a quota increase. To request a quota
increase, first upgrade to a Pay-As-You-Go subscription"). Todas las familias de VM con
quota ya asignada por defecto (Basic A, Standard A0-A7, B-series, D v2/v3/v4) resultaron
ser `SkuNotAvailable` (capacity restriction) al intentar desplegar — no son usables pase lo
que pase. La única familia confirmada desplegable (`Standard_D2s_v7`, familia
`StandardDsv7Family`) tiene quota 0 y no se puede subir.

Dos caminos para desbloquear, sin decidir todavía:
1. Upgrade de la suscripción a Pay-As-You-Go (decisión de facturación, no tomada).
2. Abandonar la VM para este caso y correr WireGuard/wiki en Azure Container Instances en
   vez de VM (ACI soporta agregar la capability `NET_ADMIN` a un contenedor Linux — sin
   confirmar si alcanza para crear la interfaz TUN que WireGuard necesita).

Los scripts de esta sección se dejan escritos y documentados para no repetir el trabajo de
diseño cuando se desbloquee cualquiera de los dos caminos, pero **nadie los ha corrido**.
La cuenta de Azure del lab fue limpiada por completo (`./lab-azure.sh down`) el
2026-08-02, así que ni siquiera hay infraestructura viva contra la cual validarlos ahora
mismo.

## Motivación

`dmz-wiki` (BookStack sobre `linuxserver/bookstack`) no corre en ACI: la imagen usa
s6-overlay v3, que exige ser PID 1 de su propio namespace de procesos, y los container
groups de ACI integrados a una VNet (`subnetIds`) no se lo garantizan — el arranque
falla siempre con `s6-overlay-suexec: fatal: can only run as pid 1`, ExitCode 100, a
los ~6s. Confirmado de forma determinística contra el YAML real sin modificar (ver
memoria de proyecto `aci_platform_limitations` / `dmz_wiki_blocked`). No es un bug de
config — es una limitación de la plataforma ACI, no arreglable desde el Dockerfile o el
YAML del wiki.

Alternativa evaluada y descartada por ahora: reconstruir BookStack desde cero sin
s6-overlay (mismo patrón que `filesrv`/`wiki-db`, imagen propia horneada). Válida pero
más trabajo que simplemente correr el `docker-compose.yml` que `sabana-corp-dmz` ya
tiene y que nunca dependió de ACI.

Un solo movimiento (wiki + wiki-db a una VM, vía docker-compose) resuelve tres
problemas de una vez:

1. **s6-overlay funciona.** Docker plano en una VM da PID 1 real al entrypoint — sin
   reconstruir BookStack ni cazar una imagen/tag alternativo sin s6.
2. **Vuelve el volumen `wiki_bookstack_config:/config`.** Cierra el gap de
   persistencia documentado en `yamls/README.md` ("Persistencia — pendiente para
   `wiki`"): hoy, sin volumen, BookStack pierde sus keys/config si el contenedor de
   ACI se reinicia.
3. **Vuelve la red interna `wiki_backend`.** En el `docker-compose.yml` original,
   `wiki-db` solo es alcanzable desde `wiki` vía una red bridge interna
   (`internal: true`). Hoy en ACI, `dmz-wiki-db` está expuesto directamente en
   `snet-dmz-shared` (10.50.0.4:3306) sin ese aislamiento. En la VM, docker-compose
   restaura el aislamiento tal como está diseñado.

El resto de la DMZ y de team1 (18 contenedores ya corriendo en ACI) sigue igual, sin
tocarse. Solo se mueven estos dos servicios.

## Pregunta resuelta: ¿puede la VM ir en `snet-dmz-shared`?

**No.** `snet-dmz-shared` está delegada a `Microsoft.ContainerInstance/containerGroups`
(`az network vnet subnet update --delegations ...`, ver `lab-azure.sh:delegate_dmz_subnet`).
La delegación de subred en Azure es exclusiva: una vez delegada a un servicio, esa
subred solo admite recursos de ese tipo — la NIC de una VM no puede desplegarse ahí. El
intento fallaría con un error de conflicto de delegación.

**Resuelto**: se creó `snet-dmz-vm` (`10.51.0.0/24`) en `lab-azure.sh:create_vnet` — una
DMZ paralela, sin delegar, exclusiva para servicios que necesitan Docker plano en vez de
ACI. `snet-mgmt` (10.99.0.0/24) queda reservada para el jumpbox/staff, sin mezclarse con
servicios de reto — separación más limpia si más adelante se necesitan reglas NSG
distintas para una y otra (ver `docs/plans/network-segmentation-nsgs.md`: el borrador de
reglas ya trata `snet-dmz-vm` igual que `snet-dmz-shared` — alcanzable desde los equipos,
sin permiso de iniciar conexiones hacia ellos — y a `snet-mgmt` como plano de staff,
inalcanzable para equipos).

El enrutamiento entre subredes de la misma VNet ya funciona por defecto en Azure (sin
peering ni rutas adicionales, ver `yamls/README.md` "Acceso desde la red interna") — una
VM en `snet-dmz-vm` puede alcanzar `10.60.1.0/24` (team1) sin configuración extra, y
viceversa. Ningún NSG bloquea esto hoy porque no se ha creado ninguno sobre esas
subredes — ver `docs/plans/network-segmentation-nsgs.md` para el diseño (todavía sin
implementar) que lo restringiría.

Ventaja adicional sobre el estado actual: la VM tiene una **IP privada fija propia**
(asignada al crear la NIC), no una IP por DHCP que hay que leer con
`az container show --query ipAddress.ip` y parchear con `sed` en el YAML del
dependiente (como hoy hace `deploy_dmz` para `dmz-wiki-db` → `dmz-wiki`). Eso simplifica
el `docker-compose.yml` (los hostnames del compose, `wiki-db`, siguen funcionando vía la
red de Docker dentro de la misma VM — no dependen para nada de la IP de Azure).

## Bloqueo actual: Azure for Students no puede pedir quota de VM

Confirmado 2026-08-02 con pruebas reales de `az vm create` (no solo lectura de quotas):

- Cuota de `Microsoft.Compute` en `eastus2` (y se verificó que la asignación por defecto es
  idéntica en todas las regiones probadas: eastus, westus2, centralus, southcentralus,
  westus, westeurope) es **0** para toda familia de VM moderna
  (`StandardDsv7Family`/`StandardDsv6Family`/etc).
- Las familias que sí tienen quota >0 por defecto (`basicAFamily`, `standardA0_A7Family`,
  `standardBSFamily`, `standardDv3Family`, `standardDv4Family`, ...) son **todas**
  `SkuNotAvailable` (capacity restriction) al intentar un `az vm create` real — quota
  fantasma, Azure no tiene capacidad para desplegarlas en esta suscripción pase lo que
  pase.
- La única familia confirmada realmente desplegable es `StandardDsv7Family`
  (`Standard_D2s_v7` pasa validación hasta topar con el quota check), pero está en 0.
- El formulario de aumento de quota (`New Quota Request` / `Create a support request` →
  Service and subscription limits) responde explícito: **"Your subscription isn't
  eligible for a quota increase. To request a quota increase, first upgrade to a
  Pay-As-You-Go subscription."** No hay ticket de soporte que lo evite — es una regla de
  elegibilidad por tipo de oferta, no un problema de aprobación.

Esto también bloquea, además del wiki, cualquier otro plan que dependa de una VM en esta
cuenta (ej. un gateway WireGuard dedicado) mientras siga siendo Azure for Students sin
upgrade.

## Pasos de implementación (escritos, sin correr — bloqueado en quota)

Ya existen como código, no como lista de pasos manuales:

- `yamls/templates/wiki-vm-compose.yml.tpl` → `yamls/generate-wiki-vm.sh` genera
  `yamls/generated/wiki-vm-docker-compose.yml` (wiki + wiki-db + red `wiki_backend`,
  mismas imágenes `maosuarez/sabanacorp-wiki` / `maosuarez/sabanacorp-wikidb` que ya usa
  la DMZ en ACI, mismos secretos literales que `dmz-wiki.yaml.tpl`/`dmz-wiki-db.yaml.tpl`).
- `yamls/wiki-vm/cloud-init.yaml` — instala Docker Engine + compose plugin al primer
  arranque vía el script oficial de Docker (`get.docker.com`).
- `lab-azure.sh:create_wiki_vm()` (comando `./lab-azure.sh deploy-wiki-vm`) — crea
  `vm-wiki` en `snet-dmz-vm` sin IP pública ni NSG, espera a que Docker esté listo, y
  copia+levanta el compose vía `az vm run-command invoke` (no usa SSH — evita depender de
  `nsg-jumpbox`/IP pública para la administración inicial).

Riesgos no verificados porque nunca corrió, a revisar la primera vez que se pruebe de
verdad:

- **Salida a internet de `snet-dmz-vm`**: el cloud-init necesita descargar el script de
  Docker. No se confirmó si esta subred tiene salida por defecto (Azure la está
  deprecando para subredes nuevas) — los contenedores ACI de la DMZ sí bajan imágenes de
  Docker Hub hoy, pero eso no prueba nada sobre `snet-dmz-vm` (subred distinta, sin
  containerInstance).
- **`az vm run-command invoke`** nunca se probó en esta suscripción — si falla, hay que
  caer al camino con SSH + `nsg-jumpbox` (ya existe, ver más abajo) en vez de run-command.
- Después de que `docker compose up -d` corra por primera vez, sigue pendiente: verificar
  acceso desde un contenedor ACI de la DMZ (`az container exec` a `dmz-decoy-nas` → `curl`
  a la IP privada de la VM), y actualizar `yamls/templates/dmz-wiki*.yaml.tpl` +
  `yamls/README.md` para retirar esos dos del flujo de `deploy_dmz` una vez la VM
  reemplace a los contenedores ACI equivalentes.

Se había creado (en una sesión de prueba anterior, ya destruida junto con el resto del
RG el 2026-08-02) un NSG `nsg-jumpbox` con SSH (22) restringido a una IP pública — si se
necesita SSH real en vez de run-command, hay que recrearlo, la definición no quedó
guardada en este repo.

## Abierto / no decidido

- Camino de desbloqueo: upgrade a Pay-As-You-Go (decisión de facturación del dueño de la
  cuenta) vs. abandonar VM y mover wiki/WireGuard a ACI con capability `NET_ADMIN`
  (sin confirmar si ACI lo soporta para crear interfaces TUN).
- Costo/tiempo de vida de la VM una vez exista: a diferencia de ACI (pay-per-second,
  fácil de tirar y recrear), una VM acumula costo mientras esté encendida — decidir si se
  apaga (`az vm deallocate`) fuera de horarios de prueba/evento.
- Tamaño real de la VM (`WIKI_VM_SIZE`, default `Standard_D2s_v7` en el script): elegido
  solo porque fue la única familia confirmada desplegable en las pruebas, no por
  necesidad de recursos del wiki en sí (BookStack + MariaDB para un CTF de un día es
  liviano).

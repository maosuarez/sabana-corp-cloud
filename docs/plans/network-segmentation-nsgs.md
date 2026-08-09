# Plan: reglas NSG de segmentación entre subredes

## Estado

No implementado. Solo diseño/documentación por ahora — el pedido explícito fue
"documentemos eso", no aplicarlo todavía. Ver `CLAUDE.md` ("Arquitectura de red
objetivo") para el estado actual (libre albedrío total, sin un solo NSG creado sobre
las subredes del lab; el único NSG que existe hoy, `nsg-jumpbox`, es ad hoc para SSH de
un jumpbox de prueba y no expresa ninguna política de segmentación real).

## Problema

Azure enruta por defecto entre todas las subredes de una misma VNet, sin restricción.
Hoy (`vnet-ctf-lab`, `10.0.0.0/8`) eso significa:

- `snet-team1` puede alcanzar `snet-team2`, `snet-team3`, etc. — rompe el aislamiento
  entre equipos que el CTF necesita (un equipo podría atacar directamente la
  infraestructura de otro en vez de la suya).
- Cualquier subred puede alcanzar `snet-mgmt` — si algún día ahí vive CTFd,
  Provisioner, Monitor o el jumpbox de administración, un participante podría
  alcanzarlos directamente sin pasar por ningún control.
- Un contenedor de `snet-dmz-shared` o `snet-dmz-vm` comprometido (son objetivos del
  CTF — filesrv, wiki, parking, decoys, todos pensados para ser vulnerados) podría, en
  teoría, iniciar conexiones hacia `snet-teamX` o `snet-mgmt` y usarse como pivote más
  allá de lo que el diseño del reto contempla.

Esto ya se había identificado como gap en la decisión de diseño del xss-bot compartido
(`CLAUDE.md`, "xss-bot es N instancias") y en `yamls/README.md` ("Acceso desde la red
interna") — este doc es donde se cierra ese pendiente con una propuesta concreta.

## Modelo de amenaza (resumen)

- Los **equipos son mutuamente no confiables entre sí** — cada uno debe poder atacar
  solo su propia infraestructura y los servicios compartidos de DMZ, nunca la
  infraestructura de otro equipo.
- La **DMZ (compartida y DMZ-VM) es superficie de ataque intencional** — se espera que
  los equipos la exploten. No debe, a su vez, poder iniciar conexiones hacia los
  equipos (evita que comprometer un decoy/wiki se convierta en pivote hacia team1 en
  vez de ser un callejón sin salida como está pensado).
- **`snet-mgmt` es plano de staff** — CTFd, Provisioner, Monitor y cualquier tooling de
  administración. Ningún equipo ni servicio de DMZ debe poder alcanzarlo. El tráfico
  válido es en la dirección contraria (staff/monitoring iniciando hacia equipos y DMZ
  para scraping, health checks, etc.).
- **`snet-wg-gateway` es la puerta de entrada** — recibe tráfico de clientes VPN desde
  internet y lo enruta hacia adentro. **Resuelto en `docs/plans/wireguard-vpn-gateway.md`**
  (2026-08-08): el control de acceso ahí no se implementa como NSG (ver nota bajo la matriz).

## Matriz de reglas propuesta

Origen (filas) → Destino (columnas). `✓` permitido, `✗` denegado, `—` no aplica /
fuera de alcance de este doc.

| Origen \ Destino  | snet-teamX (mismo) | snet-teamX (otro) | snet-dmz-shared | snet-dmz-vm | snet-mgmt | snet-wg-gateway |
|-------------------|:---:|:---:|:---:|:---:|:---:|:---:|
| **snet-teamX**    | ✓   | ✗   | ✓   | ✓   | ✗   | —   |
| **snet-dmz-shared** | ✗ | ✗   | ✓   | ✓   | ✗   | —   |
| **snet-dmz-vm**   | ✗   | ✗   | ✓   | ✓   | ✗   | —   |
| **snet-mgmt**     | ✓   | ✓   | ✓   | ✓   | ✓   | —   |
| **snet-wg-gateway** | — | —   | —   | —   | —   | —   |

Notas sobre la matriz:

- **snet-teamX → snet-teamX (mismo)**: tráfico intra-equipo, siempre permitido (es
  como los 4 contenedores de un mismo equipo se comunican entre sí hoy).
- **snet-teamX → otro snet-teamY**: denegado — aislamiento entre equipos.
- **snet-teamX → DMZ (shared/vm)**: permitido — es el objetivo real del reto (pivotar
  desde el edificio propio hacia filesrv/wiki/parking/decoys).
- **DMZ → snet-teamX**: denegado en ambas direcciones — comprometer un servicio DMZ no
  debe dar acceso a la red de ningún equipo.
- **DMZ-shared ↔ DMZ-vm**: permitido entre sí (ambas son "la DMZ", solo separadas por
  la limitación técnica de ACI vs. VM — ver `docs/plans/wiki-on-vm.md`). Ej.: si algún
  día un contenedor de `snet-dmz-shared` necesita hablar con el wiki en
  `snet-dmz-vm`, no hay razón de negarlo.
- **Nadie (equipos ni DMZ) → snet-mgmt**: denegado — plano de staff aislado.
- **snet-mgmt → todo**: permitido — monitoreo/administración necesita visibilidad
  amplia. Si esto resulta demasiado permisivo cuando se implemente Monitor/Provisioner
  de verdad, revisar (podría acotarse a los puertos específicos de scraping en vez de
  "todo").
- **snet-wg-gateway**: fila/columna deliberadamente en blanco — el control de acceso de los
  clientes VPN no se modela en esta matriz. Ver nota debajo.

## Notas de implementación (para cuando se decida aplicar esto)

- Un NSG por subred (Azure permite asociar un NSG a una subred directamente, sin
  depender de NICs individuales) — más simple de razonar que un NSG compartido con
  reglas por IP de origen.
- Los NSG de subredes delegadas a ACI (`snet-dmz-shared`) sí son compatibles —
  Azure permite asociar NSGs a subredes delegadas a `Microsoft.ContainerInstance`.
  No debería haber sorpresas ahí, pero conviene probarlo contra un solo contenedor
  antes de aplicarlo a los 14 que ya corren, para no romper `deploy_dmz` a mitad de un
  evento.
- Las reglas "denegar equipo→equipo" necesitan una entrada explícita de **deny** por
  cada rango de equipo activo (o una regla que solo permita el propio bloque
  `10.60.<N>.0/24` de cada subred de equipo y deniegue el resto de `10.60.0.0/16`) —
  como `add-team <N>` crea subredes bajo demanda, el NSG de cada `snet-teamX` debería
  generarse/actualizarse en el mismo paso que crea la subred (`lab-azure.sh:
  add_team_subnet`), no a mano.
- Recomendado: aplicar esto primero contra un solo equipo de prueba (team1, que ya
  está desplegado) y confirmar con `az container exec` + `curl`/`nc` cruzado entre
  subredes que las reglas se comportan como se espera, antes de generalizarlo a
  `add-team` para futuros equipos.
- Orden de rollout sugerido: (1) bloquear equipo↔equipo, (2) bloquear
  DMZ→equipos, (3) bloquear todo→mgmt — de menor a mayor probabilidad de romper algo
  que ya funciona, para poder aislar rápido cuál regla causó un problema si algo se
  rompe.

## Abierto / no decidido

- ~~Política de `snet-wg-gateway`~~ — **resuelto, no vía NSG.** El control de acceso de
  los clientes VPN se implementa en el propio gateway (`vm-wg-gateway`): reglas
  `iptables FORWARD` por IP de túnel WireGuard, con política `DROP` por defecto — no en
  una NSG de subred. Motivo: esta matriz es de grano por-subred, y el control que
  necesita la VPN es por-peer (dos equipos comparten la "clase" `snet-team<N>` pero
  deben tener acceso mutuamente exclusivo, algo que un NSG de subred no expresa sin
  duplicar por completo el ciclo de vida de `add-team`). Ver
  `docs/plans/wireguard-vpn-gateway.md` para el diseño completo. El resto de esta matriz
  (equipo↔equipo, DMZ→equipos, todo→mgmt) sigue sin implementarse y sigue aplicando tal
  cual al tráfico *dentro* de la VNet que no pasa por el gateway.
- Si Monitor/Provisioner terminan viviendo en `snet-mgmt` con necesidad de exponer un
  puerto hacia equipos (ej. Provisioner respondiendo a un webhook), la regla
  "`snet-mgmt → todo` sí, nadie → `snet-mgmt`" tendría que ganar una excepción
  puntual — no bloquear ese caso preventivamente sin saber si aplica.

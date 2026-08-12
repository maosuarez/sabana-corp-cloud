# Plan: `nmap-sabana-corp` (herramienta de descubrimiento para el participante)

## Estado

**Diseño. NO IMPLEMENTADO — no existe código, no existe el paquete npm, no se ha tocado nada de
Azure.** Este documento decide arquitectura; la implementación es un trabajo posterior y separado.

Estado de lo que este plan **asume ya existente y validado** (no lo re-valida, solo lo usa):

- `vm-wg-gateway` + túneles por equipo, `AllowedIPs` = `10.60.<N>.0/24, 10.50.0.0/24,
  10.51.0.0/24, 10.200.0.1/32`, control de acceso real por `iptables` — validado 2026-08-08
  (`docs/plans/wireguard-vpn-gateway.md`).
- dnsmasq en el gateway, zona plana `sabanacorp.internal`, resolutor alcanzable en `10.200.0.1`
  desde cualquier túnel — validado 2026-08-10 (`docs/plans/internal-dns.md`).
- Caveat vigente y **permanente por diseño**: hay hosts CON registro DNS y hosts SIN registro
  (los desplegados antes de la migración a DNS). Ver "El caso mixto".

Tres supuestos **no verificados** de los que depende el diseño, y que hay que medir antes de
escribir código de producción (Fase 0, misma convención que `internal-dns.md`):

1. Que dnsmasq responde **PTR** para los registros de `hostsdir` cuando se le pregunta directo
   (`dig -x 10.60.1.4 @10.200.0.1`) desde el túnel de un equipo. De esto depende toda la capa de
   nombres de la herramienta.
2. Qué devuelve un puerto **cerrado** de un contenedor ACI vivo (RST → `ECONNREFUSED`, o descarte
   → timeout). Determina si "cerrado" es señal de vida útil o no.
3. **Presión de conntrack en el gateway** con N equipos barriendo a la vez. Es el riesgo real de
   este plan y está desarrollado en "Lo que se rompe primero".

## Problema

Se le quiere pedir al participante que descubra por sí mismo qué hay en su entorno al arrancar un
reto, en vez de entregarle una lista de servicios. Es la postura correcta para un CTF —
reconocimiento es parte del juego — pero hoy es inviable:

- Un `nmap` real contra `10.0.0.0/8` son 16.7 M de direcciones: horas. El lab dura una tarde.
- Un `nmap` contra el alcance correcto exige que el participante sepa cuál es su alcance, que hoy
  solo está escrito dentro del `.conf` de WireGuard y que nadie lee.
- nmap **no está instalado** en la mayoría de laptops de estudiantes, y en Windows implica
  instalador + Npcap + permisos de administrador. En un evento eso son 40 minutos de soporte antes
  del primer reto.
- Las IPs de ACI son dinámicas: cualquier guía impresa con IPs caduca en el siguiente redespliegue.
  Lo mismo aplica a una lista de servicios repartida en PDF.

Lo que se quiere: un comando, sin privilegios, multiplataforma, que en segundos responda **"qué
hay vivo en lo que yo alcanzo, y en qué puertos"**, calculado en tiempo real contra la red real.

Lo que **no** se quiere, y hay que dejarlo escrito porque es la tentación obvia: que la
herramienta sea una chuleta. Si dice más de lo que diría un escaneo legítimo, deja de ser una
herramienta de reconocimiento y pasa a ser una solución parcial de los retos.

## Decisión de diseño: alcance desde el túnel, nombres desde el resolutor, resultados desde la red

La herramienta combina las dos ideas planteadas, pero con una jerarquía estricta entre ellas —
**no son dos caminos equivalentes**:

1. **El alcance (qué CIDRs barrer) se deriva del túnel WireGuard activo**, no del DNS y no de una
   tabla por equipo. El túnel ya *es* la respuesta a "qué puedo alcanzar": el gateway lo aplica con
   `iptables` y el cliente lo aplica con `AllowedIPs`.
2. **La existencia de un host y sus puertos se determinan siempre con una conexión TCP real** al
   host. Nunca con DNS, nunca con una tabla, nunca con caché.
3. **El DNS es únicamente una capa de nombres sobre los resultados**: se consulta *después* de
   saber qué está vivo, para decorar cada IP con su FQDN si lo tiene. Si el DNS falla, la
   herramienta sigue funcionando y muestra IPs.

Esta jerarquía es la decisión importante del documento, y es la misma forma del "las env vars se
quedan en IP" de `internal-dns.md`: **el DNS decora, no manda.** Un dnsmasq caído degrada el
output (columna FQDN vacía), no lo invalida.

### Por qué el DNS no puede ser la fuente de verdad (idea 2 como camino principal: descartada)

La enumeración por DNS es más rápida y más elegante, y aun así se descarta como mecanismo
principal por tres razones independientes:

- **No ve los hosts sin registro.** El caveat de `internal-dns.md` (team1, team2 y la DMZ vieja no
  tienen `dnsConfig` ni, en el caso de contenedores recreados a mano, registro actualizado) no es
  transitorio: cualquier contenedor que alguien recree fuera del flujo normal queda sin nombre
  hasta el siguiente `dns-sync`. Una herramienta que reporte "en tu red no hay nada" porque el
  equipo se desplegó antes de la migración es **activamente incorrecta**, y en un evento eso se
  traduce en un equipo bloqueado que cree que su reto está caído.
- **Requiere adivinar el espacio de nombres.** Resolver `<svc>.team<N>...` obliga a fijar un rango
  de `N` (¿1..50? ¿1..255?) dentro del paquete. Eso es exactamente el "hardcodeo por equipo" que el
  requisito prohíbe, disfrazado de rango.
- **Resolver no es alcanzar** (decisión ya tomada y probada en `internal-dns.md`). Una lista
  construida desde DNS mezcla lo alcanzable con lo que no lo es. Habría que verificarlo con TCP de
  todas formas — o sea, el escaneo no se ahorra, solo se ahorra el barrido.

Lo que sí aporta la idea 2, y se conserva: el DNS es la única forma barata de poner nombres, y el
**PTR** resuelve el problema del caso mixto sin enumerar nada (ver abajo).

### Por qué no un backend en el lab

Un servicio de inventario (FastAPI en la DMZ, o reutilizar Prometheus de `vm-monitor`) devolvería
la respuesta exacta en una llamada. Descartado, por el mismo criterio con el que se descartó el
bot compartido en `CLAUDE.md`:

- **Sabe demasiado.** El inventario real incluye equipos que el participante no puede alcanzar.
  Filtrarlo por equipo exige autenticar al participante — inventar authn/authz por equipo para un
  evento de una tarde, con el `.conf` como única credencial existente.
- **Mentiría sobre lo único que importa.** El inventario dice qué existe; el participante necesita
  saber qué *alcanza*, y eso lo decide `iptables` en el gateway. Un backend que responda "existe
  10.60.7.5" para un equipo que no lo alcanza produce el peor bug de soporte posible.
- **`vm-monitor` está en `snet-mgmt`**, que por decisión explícita no se publica ni se alcanza
  desde los túneles de equipo. Exponerlo sería abrir el plano de staff para ahorrar 5 segundos de
  escaneo.
- **Es infraestructura nueva** (un contenedor más, un despliegue más, una superficie más que se
  cae el día del evento) para un problema que se resuelve 100% del lado del cliente con lo que ya
  existe.

**Conclusión: cero componentes nuevos en el lab.** El plan requiere un ajuste de `sysctl` en el
gateway (ver "Lo que se rompe primero") y un cambio en el generador de clientes VPN; nada más.

### Por qué no un inventario estático en el paquete

Descartado sin discusión: viola el requisito de dinamismo, caduca en el primer redespliegue, y
convierte cada `add-team` en una publicación de npm.

## Cómo se determina el alcance, en tiempo real

Cadena de fuentes, en orden. La primera que produzca un resultado gana; todas son deterministas y
ninguna requiere privilegios.

**S1 — `--cidr <a,b,c>` (explícita).** Escape hatch para staff y para casos raros (conflictos de
ruta, túnel admin). Siempre disponible, nunca automática.

**S2 — `--conf <ruta al .conf>`.** Parsea `AllowedIPs` del archivo que el participante ya
descargó. Es la fuente **autoritativa**: es literalmente lo que el gateway le concedió. Se usa si
el usuario la pasa. **No se auto-descubre**: en Linux/macOS los `.conf` viven en
`/etc/wireguard/` (solo root) y en Windows el cliente oficial los guarda cifrados con DPAPI en
`C:\Program Files\WireGuard\Data\Configurations\*.conf.dpapi` (requiere administrador). Auto-
descubrirlos exigiría privilegios en dos de los tres SO, que es justo lo que este diseño evita.

**S3 — derivación desde la dirección de la interfaz de túnel (camino por defecto).**
`os.networkInterfaces()` de Node lista todas las interfaces con sus IPv4, **sin privilegios y con
el mismo código en Windows, macOS y Linux** (el nombre de la interfaz cambia — `wg0`, `utun4`, el
adaptador de WireGuard — pero la dirección no). Se busca una dirección dentro de `10.200.0.0/16`,
que es el overlay del túnel, y de ella se deriva el equipo:

```
10.200.<N>.2   ->  equipo N      (lo asigna create_wg_team_peer, lab-azure.sh:858)
10.200.0.2     ->  peer admin    (lab-azure.sh:920) -> no hay equipo; ver abajo
```

De `N` sale el alcance: `10.60.<N>.0/24` + `10.50.0.0/24` + `10.51.0.0/24`.

Esto **no es hardcodear IPs**: no hay ni una dirección de host en el paquete. Lo que se codifica es
el *plan de direccionamiento del lab* (tres constantes de CIDR y la regla `10.200.N.2 → team N`),
que es una constante arquitectónica documentada en `CLAUDE.md`, cambia solo si se rediseña la VNet
entera, y vive en **un solo archivo** del paquete (`src/catalog.js`).

**S4 — tabla de rutas del SO: evaluada y descartada.** Es la fuente más "real" (refleja lo que el
kernel hará de verdad), pero exige parsear tres formatos distintos (`ip -4 route show dev wg0`,
`route print -4`, `netstat -rn -f inet`), cada uno con sus variantes de locale y de versión. Tres
parsers frágiles para obtener una información que S2 y S3 ya dan de forma exacta. Se descarta por
la regla de simplicidad; si S3 resultara poco fiable en algún SO, esta es la primera alternativa a
reconsiderar.

### Casos borde del alcance

| Caso | Comportamiento |
|---|---|
| No hay interfaz en `10.200.0.0/16` | Error accionable: "no veo un túnel de Sabana Corp activo; levanta la VPN o pasa `--conf`/`--cidr`". **Nunca** barrer a ciegas. |
| Dirección `10.200.0.2` (admin) | No hay equipo derivable. Barre solo las dos DMZ y avisa: "peer admin detectado; usa `--cidr` para más alcance". |
| Varias interfaces en `10.200.0.0/16` | Error, listando las candidatas y pidiendo `--conf`/`--cidr`. Adivinar aquí es peor que preguntar. |
| Equipo > 254 | El propio esquema de peers (`10.200.<N>.2`) ya no da más; es un límite preexistente del lab, no de esta herramienta. Se documenta, no se resuelve aquí. |
| La LAN del participante usa `10.60.x` / `10.50.x` | Conflicto de rutas: puede escanear su propia LAN y ver hosts ajenos al lab. Mitigación: el output marca el origen del alcance, y `--cidr` permite acotar. Ver "Riesgos". |

## Cómo se escanea

**TCP connect scan real, sin sockets raw, sin root.** `net.Socket().connect()` de Node. No hay SYN
scan, ni detección de OS, ni fingerprinting de versión, ni ICMP — no por simplificar el output,
sino porque todo eso requiere privilegios elevados o librerías nativas, que es precisamente lo que
haría inviable la distribución.

Aquí conviene ser preciso con lo de "medio simulada": **los resultados no son simulados en
absoluto**. Lo que está acotado es el *método* (connect en vez de SYN, catálogo fijo de puertos,
alcance fijado por el túnel). El paquete **nunca imprime un resultado que no midió**. Un "puerto
abierto" falso le cuesta a un equipo media hora de reto; la regla es: cero resultados sintéticos,
cero caché entre corridas, cero valores por defecto que finjan ser medidas.

### Dos fases

**Fase A — descubrimiento de hosts.** Se sondea un subconjunto pequeño de puertos de alta
probabilidad (`80, 22, 3306, 8080`) sobre todas las direcciones del alcance (3 × /24 = 762
direcciones útiles → ~3.048 intentos). En cuanto un host responde por cualquier puerto, se
**cancelan los sondeos restantes de ese host** (menos tráfico, menos conntrack, más rápido).

**Fase B — detalle de puertos.** Solo contra los hosts vivos de la Fase A (típicamente 15-25), con
el catálogo completo de puertos del lab (~18). Son ~400 intentos: instantáneo.

Coste típico esperado: **5-8 s en total**, dominado por el timeout de las direcciones vacías de la
Fase A. Sin la Fase A/B separadas serían ~13.700 intentos y ~4× más presión sobre el gateway.

### Definición de "vivo"

**Un host está vivo si al menos un puerto del catálogo responde** (conexión aceptada o rechazada
explícitamente). No hay ping. Consecuencia honesta que hay que documentar en el README del
paquete: un host sin ningún puerto conocido abierto es indistinguible de una IP vacía — y para el
propósito del participante eso está bien, porque un host que no expone nada alcanzable no es un
host "disponible".

Si el supuesto 2 de Fase 0 confirma que ACI devuelve RST en puertos cerrados, `ECONNREFUSED` se
trata como **evidencia de host vivo con ese puerto cerrado**; si resulta que descarta, el timeout
es indistinguible de IP vacía y no se pierde nada (el catálogo cubre los puertos que este lab
realmente publica).

### Catálogo de puertos

Unión de lo que las plantillas del repo publican de verdad — un solo array en `src/catalog.js`,
con un comentario que apunte a las plantillas de origen para que no se desincronice:

```
21  25  22  80  110  143  445  554  873  3000  3306  5432  8000  8080  8443  9090  9100  9418  443
```

(equipo: 3306, 80, 22, 80 — DMZ: 8080, y los decoys; VMs de `snet-dmz-vm`: 80 y 443 para wiki y
CTFd). Ampliable con `--ports`. Añadir un puerto es un cambio de versión menor del paquete, y
**no** requiere tocar nada del lab.

## Cómo se resuelven los nombres — y el caso mixto

**Se consulta el resolutor del lab directamente, no el del sistema operativo.** Node permite
`new dns.Resolver()` + `setServers(['10.200.0.1'])`, que habla c-ares contra esa IP e **ignora por
completo la configuración DNS del SO**.

Esto es una decisión con más peso del que parece: elimina de un plumazo toda la matriz de
split-DNS por sistema operativo documentada en `internal-dns.md` ("Cliente WireGuard y split-DNS
por sistema operativo"). No importa si Windows aplicó la regla NRPT, si `wg-quick` en Linux falló
por falta de `openresolv`, si el participante borró la línea `DNS =` del `.conf`, o si está en
WSL2 con `/etc/resolv.conf` regenerado. La herramienta funciona igual en todos esos casos, porque
no usa el stack de resolución del SO. El único prerrequisito es que `10.200.0.1/32` esté en
`AllowedIPs` — que ya lo está desde la Fase 2 del plan de DNS.

**El mecanismo es PTR (reverse), no forward.** Para cada host vivo se consulta
`<inv>.in-addr.arpa` contra `10.200.0.1`. Motivos:

- **Resuelve el caso mixto sin enumerar nada.** Un host con registro devuelve su nombre canónico
  (dnsmasq genera el PTR a partir del primer nombre de cada línea del `hostsdir` — decisión ya
  documentada en `internal-dns.md`, "El primer nombre de cada línea es el canónico"). Un host sin
  registro devuelve NXDOMAIN y se muestra con `-`. No hay que adivinar nombres ni rangos de equipo.
- **Es O(hosts vivos)**, no O(nombres posibles): ~20 consultas, en paralelo, milisegundos.
- **Nunca inventa.** Si el registro está obsoleto (IP vieja), el PTR simplemente no existe para la
  IP nueva → columna vacía, no un nombre equivocado. Es el modo de fallo correcto.

Fallback si el PTR no funcionara (supuesto 1 de Fase 0 en rojo): resolución forward del catálogo
de nombres conocidos, acotada a **el propio equipo del participante** (derivado del túnel, no de un
rango adivinado) + los nombres fijos de la DMZ, construyendo un mapa `ip → fqdn`. Es más código y
más frágil, y por eso el PTR se verifica antes de escribir nada.

**Degradación**: si `10.200.0.1` no responde en 1 s, se abandona toda la capa de nombres, se
imprime una nota (`resolutor del lab: sin respuesta — mostrando solo IPs`) y el escaneo continúa
normal. El DNS no es prerrequisito de `--scan`.

## Formato del output

Un solo comando. `npx nmap-sabana-corp` y `npx nmap-sabana-corp --scan` hacen lo mismo (`--scan`
se acepta por explicitud, es lo que va en la guía del participante).

```
nmap-sabana-corp v1.0.0 -- barrido TCP connect del entorno accesible (sin privilegios)
alcance : 10.60.3.0/24, 10.50.0.0/24, 10.51.0.0/24   (origen: interfaz de tunel 10.200.3.2)
nombres : 10.200.0.1 (resolutor del lab, activo)

-- 10.60.3.0/24 -----------------------------------------------------------------
IP           FQDN                                        PUERTOS ABIERTOS
10.60.3.4    database.team3.sabanacorp.internal          3306/tcp mysql
10.60.3.5    webapp.team3.sabanacorp.internal            80/tcp http
10.60.3.6    linux-server.team3.sabanacorp.internal      22/tcp ssh
10.60.3.7    -                                           80/tcp http

-- 10.50.0.0/24 -----------------------------------------------------------------
10.50.0.4    filesrv.dmz.sabanacorp.internal             8080/tcp http-alt
10.50.0.9    printer-01.dmz.sabanacorp.internal          80/tcp http, 9100/tcp jetdirect
...

-- 10.51.0.0/24 -----------------------------------------------------------------
10.51.0.4    wiki.dmz.sabanacorp.internal                80/tcp http
10.51.0.5    ctfd.dmz.sabanacorp.internal                80/tcp http

21 hosts vivos - 27 puertos abiertos - 762 direcciones sondeadas en 6.2 s
3 hosts sin FQDN (sin registro DNS; no es un fallo -- ver README)
```

Campos, y **nada más**: IP, FQDN canónico (o `-`), lista de puertos abiertos con una etiqueta de
servicio.

### La regla que gobierna qué se muestra

**La herramienta nunca dice nada que el número de puerto por sí solo no diga.**

- La etiqueta de servicio (`http`, `ssh`, `mysql`, `http-alt`) se deriva **exclusivamente del
  número de puerto**, con una tabla IANA genérica. Jamás del rol del host, jamás del contenedor,
  jamás de la plantilla que lo generó. `80` es `http` tanto en el webapp del reto como en un decoy.
- El FQDN se muestra **verbatim, tal como lo devuelve el resolutor**. Que
  `xss-bot.team3.sabanacorp.internal` insinúe algo no es una decisión de esta herramienta: es
  consecuencia de la zona plana ya decidida en `internal-dns.md`, donde el nombre ya es
  descubrible con `dig`. Reproducir lo que el DNS ya publica no añade filtración; inventar
  anotaciones sí.

### Lo que explícitamente NO se muestra

| No se muestra | Por qué |
|---|---|
| Banners, títulos HTTP, cabeceras, certificados TLS | Pueden echar una versión con CVE conocido, o texto del propio reto → pista |
| Versión o producto del servicio (`-sV`) | Idem, y además exigiría fingerprinting real |
| Detección de SO | Requiere privilegios y no aporta nada al juego |
| Puertos cerrados/filtrados uno por uno | Ruido; además convierte el output en un mapa del catálogo de puertos |
| Cualquier anotación de rol, reto, dificultad o vulnerabilidad | Es la línea roja del requisito |
| Subredes de otros equipos | Fuera del alcance del túnel: solo produciría timeouts y tickets de soporte |
| `snet-mgmt` (`10.99.0.0/24`) | No se publica ni se alcanza, por decisión ya tomada |
| Rutas, endpoints, directorios | No es un escáner web y no debe convertirse en uno |

`--json` emite exactamente los mismos campos en JSON (para scripting y para que el staff pueda
reutilizarlo); no hay campos "extra" ocultos en el JSON — misma información, otro formato.

## Arquitectura del paquete

### Runtime y dependencias

**Node.js ≥ 18, ESM, cero dependencias de runtime.** Todo lo que hace falta está en la librería
estándar: `net` (connect scan), `dns.Resolver` (nombres contra `10.200.0.1`), `os`
(`networkInterfaces`), `node:test` (pruebas). Cero dependencias significa: instalación instantánea,
superficie de supply-chain nula, y un solo archivo copiable como plan B (ver "Distribución").

Descartados:
- **Python** (`python -m sabana_scan`): no hay un equivalente a `npx` que funcione igual de bien en
  Windows, y la fragmentación de versiones/venv en laptops de estudiantes es peor que la de Node.
- **Go / binario compilado** (o Node SEA/`pkg`): daría un ejecutable sin runtime, pero exige
  compilar y distribuir 3 binarios, firmar/notarizar en macOS, y —el punto que lo mata— **un
  binario sin firmar que abre miles de conexiones TCP es candidato seguro a que Windows Defender o
  el EDR de la universidad lo cuarentene el día del evento**. Un `.js` legible tiene menos
  probabilidad de disparar heurísticas y, si lo hace, el participante puede leerlo.
- **Envolver nmap real**: reintroduce la instalación de nmap/Npcap y los privilegios de
  administrador, que son el problema original.

### Estructura

```
tools/nmap-sabana-corp/
  package.json          bin: { "nmap-sabana-corp": "bin/cli.js" }, type: module, files: [...]
  bin/cli.js            parseo de flags, orquestacion, codigos de salida
  src/scope.js          S1/S2/S3: --cidr, --conf, derivacion desde os.networkInterfaces()
  src/scan.js           connect scan de 2 fases, pool de concurrencia, cancelacion por host
  src/names.js          dns.Resolver contra 10.200.0.1, PTR, degradacion
  src/render.js         tabla de texto y --json
  src/catalog.js        UNICO archivo con conocimiento del lab: CIDRs, regla 10.200.N.2, puertos
  test/*.test.js        node --test, sin framework
  README.md             guia del participante (instalacion, uso, "que significa cada columna")
```

`src/catalog.js` es el archivo que hay que revisar si algún día cambia el plan de direcciones o se
añade un servicio. Está aislado a propósito: el resto del paquete no sabe nada de Sabana Corp.

### Dónde vive el código

**Dentro de este repo, en `tools/nmap-sabana-corp/`.** No en un repo aparte.

Motivo: el único contenido no genérico del paquete (CIDRs, convención de nombres, catálogo de
puertos) se deriva de `yamls/templates/*.yaml.tpl` y de `lab-azure.sh`, que viven aquí. Un repo
separado garantiza deriva silenciosa: alguien añade un decoy con un puerto nuevo y el escáner deja
de verlo, sin que nada lo señale. Conviviendo, el cambio se ve en el mismo diff y `docs/` ya es el
sitio donde este proyecto documenta ese tipo de acoplamiento.

Se evaluó `../sabana-corp-network` (donde viven las imágenes de los retos): descartado porque el
paquete no depende de las imágenes sino de la topología, que es de este repo.

### Publicación y versionado

- **Semver.** `patch` = correcciones; `minor` = cambios en `catalog.js` que alteran resultados
  (puerto nuevo, CIDR nuevo); `major` = cambio en el formato de `--json` o en los flags.
- **GitHub Actions con tag `nmap-v*`**, mismo patrón que `../sabana-corp-CTFd/.github/workflows/
  deploy.yml`: `npm ci && npm test && npm publish --provenance`, con `NPM_TOKEN` en secrets.
  Publicar a mano desde la laptop del operador está explícitamente descartado (irrepetible, sin
  rastro).
- **Reservar el nombre en npm ya**, con una versión `0.0.1` vacía, antes del evento. Un typosquat
  de un paquete que la gente va a ejecutar con `npx` en una red de laboratorio es un riesgo real y
  la mitigación cuesta cinco minutos.
- El paquete es **público**. No contiene secretos: los CIDR son RFC1918 y no significan nada fuera
  del túnel, y el catálogo de puertos es el mismo que cualquiera obtiene escaneando. Verificar
  igualmente que no entre nada de `yamls/.env.secrets` vía el campo `files` de `package.json`.

### Distribución al participante (el punto que puede arruinar el evento)

**`npx` necesita internet hacia el registro de npm en el momento exacto del evento.** El lab no
tiene salida a internet, y el acceso pasa por un portal cautivo. Aunque el túnel de WireGuard no
captura la ruta por defecto (`AllowedIPs` son solo los CIDR del lab, así que la navegación normal
del participante sigue saliendo por su ruta habitual), depender de eso el día del evento es
apostar el primer reto a la red del auditorio.

Tres capas, en orden:

1. **Pre-flight**: la guía del participante (el `README.md` que ya se genera junto al `.conf`)
   pide `npm i -g nmap-sabana-corp` **antes** de llegar, y `nmap-sabana-corp --version` como
   verificación.
2. **Copia local junto al `.conf`**: `generate-wg-client.sh` deja en
   `yamls/generated/wg-clients/` una copia del paquete empaquetada en un solo archivo
   (`nmap-sabana-corp.mjs`, ejecutable con `node nmap-sabana-corp.mjs`). Es viable *precisamente*
   porque el paquete no tiene dependencias. El participante ya recibe ese directorio: la
   herramienta viaja con el túnel que va a escanear.
3. **Sin red y sin archivo**: no hay plan C, y no hace falta — el `.conf` y la herramienta se
   entregan juntos.

## Lo que se rompe primero: conntrack en el gateway

Este es el riesgo de escala del plan, y no es del paquete sino del lab.

Cada intento de conexión de la Fase A hacia una dirección **vacía pero permitida** (dentro del
propio `/24` del equipo o de la DMZ) es un SYN que el gateway *reenvía* y que nadie contesta. Ese
flujo queda en la tabla de conntrack en estado `SYN_SENT`, y el temporizador que lo libera es
`nf_conntrack_tcp_timeout_syn_sent` — **120 s por defecto**, completamente independiente del
timeout de socket que use la herramienta. Bajar el timeout del cliente no ayuda en absoluto aquí.

Cuentas de servilleta, con 4 puertos en Fase A:

| Escenario | Entradas de conntrack en ~2 min |
|---|---|
| 1 equipo escanea | ~2.500 |
| 20 equipos escanean al arrancar el evento (caso real: todos a la vez) | ~50.000 |
| 20 equipos escaneando dos veces (segundo intento porque "no salió nada") | ~100.000 |

El `nf_conntrack_max` por defecto en una VM Ubuntu pequeña se sitúa en el orden de decenas de
miles. Si se llena, el gateway **descarta tráfico nuevo de todos los peers**, no solo del que
escanea: se cae la VPN entera para todo el mundo, con un síntoma ("todo va lento / se cortó")
que no apunta a la causa. Es el fallo más caro que puede producir esta herramienta.

Nota: el tráfico hacia **otros equipos** (bloqueado por `iptables` en `FORWARD`) no contribuye — un
paquete descartado en `FORWARD` nunca confirma su entrada de conntrack. El problema son las
direcciones vacías de las subredes que el participante **sí** tiene permitidas.

Mitigaciones, en orden de importancia:

1. **`sysctl` en el gateway** (lo único que este plan pide del lab, y es una línea):
   `net.netfilter.nf_conntrack_max=262144` y
   `net.netfilter.nf_conntrack_tcp_timeout_syn_sent=20`. Añadir a
   `yamls/wg-gateway/cloud-init.yaml` (para gateways futuros) y aplicar por `run-command` sobre la
   VM viva (patrón "live-apply, no recrear" ya usado en este repo).
2. **Fase A con pocos puertos** (4, no 18) y cancelación por host: es la diferencia entre 2.500 y
   11.000 entradas por equipo.
3. **Concurrencia por defecto moderada** (128 sockets simultáneos, no 1024). Es más lento en el
   papel y casi igual en la práctica, porque el cuello de botella es el timeout, no el paralelismo.
   Ajustable con `--concurrency` para el staff.
4. **Decisión diferida con disparador medible**: si la prueba de carga (Fase 0, supuesto 3) muestra
   que ni con el `sysctl` se sostienen N equipos simultáneos, se invierte el modo por defecto —
   pasa a ser "DNS primero" (resolver los nombres del propio equipo + DMZ, ~20 objetivos, sin
   barrido) y el barrido completo queda tras `--deep`. Sería peor herramienta (vuelve el punto
   ciego de los hosts sin FQDN) pero no tumba el gateway. **No tomar esta decisión sin la medida.**

Un `node_exporter` en el gateway daría `node_nf_conntrack_entries` y cerraría el bucle con una
alerta. Está fuera del alcance de este plan (hoy `node_exporter` solo corre en `vm-monitor`); se
anota como entrada para `docs/plans/observability-monitoring.md`.

## Cambios necesarios en el lab

Sorprendentemente pocos. La herramienta funciona contra el lab **tal como está hoy**.

| Cambio | Obligatorio | Dónde |
|---|---|---|
| `sysctl` de conntrack en el gateway | **Sí** (ver arriba) | `yamls/wg-gateway/cloud-init.yaml` + `run-command` sobre la VM viva |
| Copia del paquete junto al `.conf` + sección en el README del participante | Sí (distribución) | `yamls/generate-wg-client.sh`, `yamls/templates/wg-client-readme.md.tpl` |
| `10.200.0.1/32` en `AllowedIPs` | Ya hecho | `create_wg_peer` (`lab-azure.sh:843`) |
| dnsmasq respondiendo PTR | Ya hecho, **sin verificar desde el túnel** | Fase 0 |
| Que todos los hosts tengan FQDN | **NO** — y no debe volverse un prerrequisito | — |
| Backend / servicio nuevo | **NO** | — |

La fila más importante es la penúltima: este diseño está construido para que el caso mixto sea
permanente. Si alguien decide más adelante recrear team1/team2 para darles `dnsConfig`, la
herramienta mejora (más columnas FQDN llenas) pero no cambia. **Nunca al revés**: no convertir
"todos los hosts tienen DNS" en requisito de la herramienta, por la misma razón por la que las env
vars de los contenedores siguen en IP.

## Fases de implementación

**Fase 0 — Verificar supuestos (medio día, sin código de producción).**
1. PTR desde un túnel de equipo: `dig -x 10.60.1.4 @10.200.0.1` con `team1.conf` levantado.
2. Puerto cerrado de un contenedor ACI: `nc -vz <ip-webapp> 22` → ¿RST o timeout?
3. **Carga**: barrido sintético (script de 20 líneas, no el paquete) simulando 5 y 20 equipos
   simultáneos, midiendo `conntrack -C` en el gateway antes/durante/después, con y sin el `sysctl`.
   Es el que puede cambiar el diseño.
4. Node presente en las laptops: preguntar en la convocatoria. Determina cuánto peso tiene la
   capa 2 de distribución.

**Fase 1 — Núcleo del paquete, sin publicar.** `scope.js` + `scan.js` + `render.js` + catálogo.
Verificable contra el lab real desde la laptop del operador con `admin.conf` y `--cidr`. Sin npm,
sin cambios en el lab.

**Fase 2 — Capa de nombres.** `names.js` (PTR contra `10.200.0.1`), degradación con dnsmasq
apagado a propósito. Verificable con `team1.conf` (hosts **sin** FQDN, por el caveat) y con un
equipo desplegado después de la migración (hosts **con** FQDN) — el caso mixto se prueba de verdad,
no en teoría.

**Fase 3 — Endurecimiento del lab.** `sysctl` de conntrack en cloud-init + live-apply, y repetir
la prueba de carga de Fase 0 con el paquete real.

**Fase 4 — Publicación y distribución.** `package.json`, workflow de GitHub Actions, reserva del
nombre, bundle de un archivo en `generate-wg-client.sh`, sección en el README del participante.

**Fase 5 — Documentación.** `CLAUDE.md` (sección "Decisión de diseño" con la jerarquía
alcance/red/nombres y la regla de "no dar pistas"), `yamls/README.md`, nota cruzada en
`internal-dns.md` (el PTR pasa a tener un consumidor real) y en `observability-monitoring.md`
(conntrack del gateway). Al final a propósito: se documenta lo medido.

**Fase 6 — Explícitamente fuera del evento.** Detección de versión/banners, escaneo web, modo
"pista". Queda escrito aquí para que la decisión de no hacerlo sea deliberada.

## Plan de pruebas

```bash
# alcance (sin tunel, unitario)
node --test tools/nmap-sabana-corp/test/        # scope: 10.200.7.2 -> 10.60.7.0/24 + DMZs
                                                # scope: sin interfaz 10.200/16 -> error accionable
                                                # scope: parseo de AllowedIPs con y sin espacios

# contra el lab real, con team1.conf levantado
node bin/cli.js --scan                          # hosts de team1 + ambas DMZ, FQDN vacio donde toca
node bin/cli.js --scan --json | jq '.hosts|length'

# caso mixto real
./lab-azure.sh add-team 9                       # equipo nuevo -> SI tiene dnsConfig/registro
# levantar team9.conf y comprobar: FQDN presente en los 4, y en la DMZ vieja ausente

# resolver != alcanzar (la prueba que documenta el modelo de seguridad)
# con team1.conf: el barrido NO debe listar ningun host de 10.60.2.0/24
node bin/cli.js --scan --cidr 10.60.2.0/24      # 0 hosts vivos, y el gateway sube su contador DROP

# degradacion del DNS
az vm run-command invoke ... --scripts "systemctl stop dnsmasq"
node bin/cli.js --scan                          # mismos hosts y puertos, columna FQDN toda en '-'
az vm run-command invoke ... --scripts "systemctl start dnsmasq"

# carga (la prueba que puede cambiar el diseno)
# 5 y 20 barridos simultaneos; en el gateway, antes/durante/despues:
az vm run-command invoke ... --scripts "conntrack -C; sysctl net.netfilter.nf_conntrack_max"
# criterio: uso < 50% del maximo, y la VPN de un peer que NO escanea sigue respondiendo

# multiplataforma (no negociable: es donde vive el riesgo)
# Windows 11 (cliente oficial), macOS (app oficial), Linux (wg-quick), WSL2
```

## Riesgos y mitigación

| # | Riesgo | Impacto | Mitigación |
|---|---|---|---|
| 1 | Agotamiento de conntrack en el gateway con N equipos escaneando a la vez | **La VPN se cae para todos**, no solo para quien escanea | `sysctl` (`nf_conntrack_max`, `syn_sent=20`), Fase A de 4 puertos, concurrencia 128, prueba de carga en Fase 0 |
| 2 | El participante no tiene Node instalado | No puede usar la herramienta | Pre-flight en la convocatoria; medir en Fase 0; el `.conf` y el archivo único viajan juntos |
| 3 | `npx` falla por no haber internet en el auditorio | Falla justo al arrancar el evento | `npm i -g` previo + copia de un archivo junto al `.conf` |
| 4 | Antivirus/EDR cuarentena la herramienta ("port scanner") | Bloqueo por equipo, difícil de diagnosticar | `.js` legible en vez de binario sin firmar; concurrencia moderada; nota en el README |
| 5 | La LAN del participante solapa con `10.50/10.60` | Escanea su propia red; resultados confusos o embarazosos | Origen del alcance impreso en la cabecera; `--cidr`; nota en el README |
| 6 | `os.networkInterfaces()` no muestra el adaptador de WireGuard en algún SO/versión | La detección automática falla | Fallbacks `--conf` y `--cidr`; probar en los 4 entornos en Fase 4 |
| 7 | dnsmasq no responde PTR para entradas de `hostsdir` | Se cae la capa de nombres | Fase 0 lo prueba antes de escribir `names.js`; fallback forward acotado al propio equipo |
| 8 | El catálogo de puertos se desincroniza de las plantillas | Hosts vivos invisibles para la herramienta | Paquete en el mismo repo; comentario cruzado en `catalog.js`; el README de `yamls/` lo menciona |
| 9 | Alguien añade banners/versión "para que se parezca más a nmap" | Se filtran pistas de los retos | Regla escrita ("nada que el puerto por sí solo no diga") en `CLAUDE.md` y en el encabezado de `render.js` |
| 10 | El paquete se vuelve dependencia de los retos (una pista dice "corre el escáner") | Un fallo de la herramienta tumba un reto | La herramienta es de comodidad, nunca de plano de datos — mismo criterio que el DNS |
| 11 | Typosquatting del nombre en npm | Ejecución de código arbitrario en laptops de participantes | Reservar el nombre antes del evento; publicar con provenance; el README indica la URL exacta |
| 12 | El nombre `nmap-*` en un paquete público sugiere afiliación con Nmap | Menor, pero real | Nota explícita en el README ("no es nmap, no usa su código"); alias de bin alternativo disponible |
| 13 | El participante interpreta "0 hosts" como "el lab está caído" | Tickets de soporte | Mensaje explícito cuando hay 0 vivos: primero verificar túnel (`--conf`), luego avisar al staff |

## Criterios de aceptación

1. `npx nmap-sabana-corp --scan` con `team<N>.conf` levantado lista los 4 hosts del equipo + los de
   ambas DMZ, en **menos de 10 s**, sin privilegios de administrador, en Windows, macOS y Linux.
2. La cabecera imprime el alcance y su origen; el alcance coincide exactamente con `AllowedIPs`
   del `.conf` de ese equipo.
3. Ningún host de otro equipo aparece en la salida (aunque su nombre resuelva).
4. Hosts con registro DNS muestran FQDN; hosts sin registro muestran `-`; **ambos casos aparecen en
   la misma corrida** (el caso mixto probado de verdad).
5. Con dnsmasq detenido: mismos hosts y mismos puertos, columna FQDN vacía, sin errores.
6. La salida no contiene banners, versiones, títulos, ni ninguna anotación de rol o de reto — se
   revisa a ojo contra la tabla "Lo que explícitamente NO se muestra".
7. `--json` contiene los mismos campos que la tabla, ni uno más.
8. 20 barridos simultáneos mantienen el uso de conntrack del gateway por debajo del 50% y no
   degradan la VPN de un peer que no está escaneando.
9. Cero dependencias en `package.json`; `npm pack` produce un tarball sin secretos.
10. La copia de un archivo entregada junto al `.conf` produce salida idéntica a la del paquete
    publicado.
11. `CLAUDE.md` deja escrita la jerarquía (alcance = túnel, hechos = TCP, nombres = decoración) y
    la regla de no dar pistas.

## Abierto / no decidido

- **Detección de servicio real (banners/`-sV`)**: descartada para el evento (filtra pistas). Solo
  reconsiderable si alguien define, por servicio, qué es publicable — y eso es una decisión de
  guion del CTF, no de arquitectura.
- **Marcar qué hosts son decoys**: sería útil para soporte y **letal** para el juego. No.
- **Modo `--watch`** (re-escaneo continuo): tentador para ver un reto reiniciarse, pero multiplica
  por K la presión de conntrack del riesgo 1. Fuera hasta tener la medida de carga.
- **Telemetría** (que la herramienta reporte al staff quién escaneó y cuándo): interesante como
  señal de progreso, pero implica un backend — justo lo que este plan descarta. Encaja mejor como
  `log-queries` de dnsmasq en `docs/plans/observability-monitoring.md`, que ya está anotado ahí.
- **UDP**: el lab no publica ningún servicio UDP alcanzable (solo WireGuard 51820, que no es un
  objetivo). Sin caso de uso; además el escaneo UDP sin privilegios es poco fiable.
- **IPv6**: la VNet es solo IPv4. No aplica.
- **Reutilizar el paquete para `status` del staff**: `--json` lo permitiría, pero `lab-azure.sh
  status` ya lee el control plane de Azure, que es una fuente mejor (ve contenedores caídos, que un
  escáner no ve). No unificar.
- **Nombre del paquete**: `nmap-sabana-corp` es el pedido explícito del dueño del proyecto y se
  respeta. Alternativas si el matiz de marca molesta: `sabanacorp-recon`, `sabana-scan` (se puede
  publicar como alias de `bin` sin cambiar el paquete).

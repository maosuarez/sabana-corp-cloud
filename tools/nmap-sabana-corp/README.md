# nmap-sabana-corp

> **`0.1.0-draft`: build funcional (36/36 pruebas unitarias), pero aún NO validado contra el lab
> real** -- faltan los tres supuestos de Fase 0 del plan (PTR desde un túnel real, comportamiento
> de puerto cerrado en un contenedor ACI vivo, presión de conntrack en el gateway con N equipos
> escaneando). No usar todavía como la herramienta oficial del evento; la versión `1.0.0` reemplaza
> a esta cuando esos supuestos queden verificados. Detalle: `docs/plans/nmap-sabana-corp.md`.

Descubrimiento de red sin privilegios para el CTF de Sabana Corp. Un comando que responde "qué
hay vivo en lo que yo alcanzo, y en qué puertos" -- calculado en tiempo real contra la red real,
nunca contra una lista fija.

**No es nmap.** No usa su código, no reimplementa su motor. Solo hace una cosa que nmap también
hace (connect scan por TCP) con el nombre elegido para que quede claro qué es, a un participante
que probablemente no tiene nmap instalado.

## Instalación

```bash
npm install -g nmap-sabana-corp
nmap-sabana-corp --version   # verificacion de pre-flight, hazlo ANTES del evento
```

El lab no tiene salida a internet (portal cautivo + VPN). Si no llegaste a instalarlo antes,
buscá `nmap-sabana-corp.mjs` en la misma carpeta que tu `<equipo>.conf` -- viaja junto al túnel,
sin necesidad de red ni de `npm`:

```bash
node nmap-sabana-corp.mjs --scan
```

## Uso

Con el túnel WireGuard de tu equipo levantado:

```bash
nmap-sabana-corp
nmap-sabana-corp --scan       # exactamente lo mismo; --scan es explicito, no hace nada distinto
nmap-sabana-corp --json       # mismos campos, en JSON
```

No hace falta indicar nada más: el alcance se deriva automáticamente de la interfaz de tu túnel
(busca una dirección dentro de `10.200.0.0/16`). Otras opciones:

| Flag | Para qué |
|---|---|
| `--cidr <a,b,c>` | Alcance explícito. Escape hatch para staff o para conflictos de ruta. |
| `--conf <ruta>` | Deriva el alcance leyendo `AllowedIPs` de un `.conf` de WireGuard directamente -- es la fuente más autoritativa que hay. |
| `--ports <a,b,c>` | Suma puertos extra al catálogo del lab. |
| `--concurrency <n>` | Sockets simultáneos (por defecto 128). Bajalo si tu red es inestable. |
| `--json` | Salida en JSON en vez de tabla de texto. |
| `--version` / `--help` | Lo de siempre. |

## Cómo funciona (resumen)

1. **Alcance**: de tu túnel WireGuard (o de `--conf`/`--cidr` si los pasás). Nunca se adivina.
2. **Hechos**: cada host y cada puerto se mide con una conexión TCP real (`net.Socket().connect()`,
   sin privilegios, sin sockets raw). Un host se considera vivo si al menos un puerto del catálogo
   responde -- aceptado o rechazado explícitamente. Cero resultados simulados, cero caché.
3. **Nombres**: después de saber qué está vivo, se le pregunta al resolutor DNS del lab
   (`10.200.0.1`, nunca al de tu sistema operativo) el nombre PTR de cada IP viva. Si el resolutor
   no responde en 1 segundo, la herramienta sigue funcionando igual y muestra solo IPs.

Detalle completo de las tres decisiones (por qué en ese orden, por qué TCP y no DNS, por qué PTR y
no forward) en `docs/plans/nmap-sabana-corp.md` del repo `sabana-corp-cloud`.

## Qué significa cada columna

```
IP           FQDN                                        PUERTOS ABIERTOS
10.60.3.4    database.team3.sabanacorp.internal          3306/tcp mysql
10.60.3.7    -                                            80/tcp http
```

- **IP**: dirección real, medida en esta corrida.
- **FQDN**: nombre canónico que devolvió el resolutor del lab, o `-` si no tiene registro DNS.
  **Un `-` no es un fallo de la herramienta ni del reto** -- hay hosts en este lab que nunca
  tuvieron registro DNS (se desplegaron antes de que existiera esa capa) y van a seguir así. Que
  falte el nombre no significa que el host esté mal, ni que no puedas alcanzarlo: la columna
  siguiente (puertos) ya te lo confirma.
- **PUERTOS ABIERTOS**: puerto, protocolo y una etiqueta de servicio genérica (tabla IANA,
  derivada exclusivamente del número de puerto -- `80` es `http` sea cual sea el contenedor detrás).

## Lo que esta herramienta nunca muestra, a propósito

| No se muestra | Por qué |
|---|---|
| Banners, títulos HTTP, cabeceras, certificados TLS | Pueden filtrar una versión con CVE conocido, o texto del propio reto |
| Versión o producto del servicio (`-sV`) | Ídem, y exigiría fingerprinting real |
| Detección de sistema operativo | Requiere privilegios y no aporta nada al juego |
| Puertos cerrados/filtrados uno por uno | Ruido; convertiría el output en un mapa del catálogo interno |
| Cualquier anotación de rol, reto, dificultad o vulnerabilidad | Es la línea roja de esta herramienta |
| Subredes de otros equipos | Fuera de tu alcance real; solo producirían timeouts |
| `snet-mgmt` (infraestructura de staff) | No se publica ni se alcanza, por diseño |
| Rutas, endpoints, directorios | Esto no es un escáner web |

Si esta herramienta alguna vez te dice algo que el número de puerto por sí solo no te diría, es un
bug -- avisale al staff.

## "No veo nada" / 0 hosts vivos

Antes de pensar que el lab está caído:

1. Verificá que tu túnel WireGuard esté realmente arriba (`wg show`, o el estado en la app oficial).
2. Corré `nmap-sabana-corp --conf <tu-equipo>.conf` -- si con `--conf` tampoco aparece nada, ahí sí
   avisale al staff.

Que un host no tenga ningún puerto del catálogo abierto es indistinguible de una IP vacía -- y
para el propósito de reconocimiento eso está bien: si no expone nada alcanzable, no es un host
"disponible" para el reto.

## Resolver ≠ alcanzar

Vas a poder ver nombres de otros equipos si preguntás por ellos a mano (la zona DNS del lab es
plana, no hay `split-horizon`): reconocimiento de red es parte del juego. Que un nombre resuelva
**no** significa que lo puedas alcanzar -- el control de acceso real está en el gateway VPN, no en
el DNS. Vas a ver `webapp.team7.sabanacorp.internal`, pero conectarte a la red de otro equipo es
exactamente lo que este CTF te reta a lograr, no algo que esta herramienta te dé gratis.

## Cero dependencias, a propósito

Este paquete no depende de nada fuera de la librería estándar de Node (`net`, `dns`, `os`). Eso
significa instalación instantánea y, más importante, que podés leer el código fuente completo
(`src/`) en un rato si querés confirmar exactamente qué hace antes de correrlo en tu laptop.

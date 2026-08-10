# Plan: observabilidad central (Prometheus + Grafana en snet-mgmt)

## Estado

**Diseño, no implementado.** Ninguna fase de este documento existe todavía en el repo. Lo único
que hay hoy es `./lab-azure.sh status`, que consulta el control plane de Azure bajo demanda y no
guarda historia ni avisa de nada.

No confundir con `dmz-decoy-monitor` (`sabanacorp-decoy`, perfil `monitor`, puertos 3000/9090 en
`snet-dmz-shared`): eso es un señuelo del CTF que imita un Grafana/Prometheus y no monitorea
nada. El stack real de este plan vive en `snet-mgmt` y se llama `vm-monitor`.

## Motivación

Durante el evento hay ~93 endpoints vivos (20 equipos × 4 contenedores + 13 de DMZ + `vm-wiki` +
`vm-wg-gateway`). Hoy no hay forma de saber que el Reto 1 del equipo 14 lleva 20 minutos caído
salvo que el equipo 14 se queje. El objetivo de este plan no es "tener métricas bonitas", es
responder dos preguntas en menos de un minuto:

1. **¿Qué está roto y de quién?** (servicio + equipo, no un promedio agregado)
2. **¿Basta con reiniciarlo?** (distinguir contenedor caído de servicio colgado de dependencia
   rota)

Requisitos:
- Cero cambios en las imágenes de los retos, salvo una excepción justificada (`xss-bot`, abajo).
- Descubrimiento automático: `add-team 15` debe aparecer en el dashboard sin editar config.
- Sin IP pública. Se accede por el túnel admin de WireGuard.
- Que quepa en la cuota (10 vCPU regionales).

## Decisión de diseño: sondeo externo (blackbox), no agentes en los contenedores

Tres opciones evaluadas:

**a) Exporters/sidecars en cada container group.** Descartada. Obliga a tocar las 4 plantillas de
equipo y las 13 de DMZ; son ~93 procesos extra de RAM; y —lo determinante— el exporter queda
*dentro* de la red del equipo, donde el participante tiene root en `linux-server` tras el Reto 2.
Puede leerlo, falsearlo, o usarlo para descubrir la existencia y la IP del monitor. En un CTF el
agente de monitoreo es superficie de ataque, no solo costo. Mismo razonamiento que la decisión de
"xss-bot es N instancias, no 1 bot compartido" en `CLAUDE.md`.

**b) Solo control plane de Azure** (`az container list` → `instanceView.state`, `restartCount`).
Cero intrusión, pero solo dice "el contenedor está Running". Un MariaDB arriba con la base
corrupta, un webapp que devuelve 500, o el `xss-bot` con Chromium colgado se ven todos verdes.
Necesaria, pero insuficiente sola.

**c) `blackbox_exporter` desde `snet-mgmt`.** Prometheus prueba TCP/HTTP contra la IP:puerto real
de cada servicio, desde fuera, exactamente como lo haría el participante. Cero cambios en las
imágenes.

**Se eligen (c) como señal primaria y (b) como señal secundaria.** Juntas distinguen los tres
estados que importan operativamente:

| Control plane | Sonda blackbox | Diagnóstico | Acción |
|---|---|---|---|
| Running | OK | sano | ninguna |
| Running | falla | servicio colgado o dependencia rota | reiniciar el contenedor |
| Terminated / restartCount subiendo | falla | crash loop | mirar logs antes de reiniciar |
| no existe | falla | grupo borrado | redesplegar (`restore`) |

## Decisión de diseño: descubrimiento vía `az container list`, no targets estáticos

Este es el problema real del plan, no Grafana.

ACI no da DNS entre container groups (ya documentado en `CLAUDE.md`), así que no hay nombre
estable que scrapear. Y las IPs privadas **no son estables ante recreación**: si un container
group se borra y se vuelve a crear, toma otra IP del pool de la subred. Un `targets.yml`
escrito a mano queda obsoleto al primer restore.

Solución: `gen-targets.sh` en `vm-monitor`, corriendo cada 60s por systemd timer:

```bash
az container list -g "$RG" \
  --query "[].{name:name, ip:ipAddress.ip, state:instanceView.state}" -o json \
  | jq '...'  > /etc/prometheus/targets/aci.json
```

Una sola llamada al control plane para todo el RG (no una por grupo — eso sí se estrellaría con
rate limits a 93 grupos). Salida en formato `file_sd` de Prometheus, con labels derivados del
nombre del container group:

| Container group | `job` | `team` | `service` |
|---|---|---|---|
| `team7-webapp` | `edificio` | `7` | `webapp` |
| `dmz-filesrv` | `dmz` | `-` | `filesrv` |
| `dmz-decoy-mail` | `dmz-decoy` | `-` | `decoy-mail` |

El mismo script emite las métricas de control plane (estado, `restartCount`) por textfile
collector — así (b) y (c) salen de la misma pasada y no hace falta un exporter de Azure aparte.

Autenticación: **managed identity** en `vm-monitor` con rol `Reader` sobre el RG. Sin service
principal, sin credenciales en disco. Ver "Riesgos" — esa identidad es lo más valioso que hay en
`snet-mgmt`.

## Decisión de diseño: alerta visual en Grafana, sin Alertmanager

El staff opera el evento presencialmente con un dashboard en pantalla. No se despliega
Alertmanager ni notificación a Telegram/Discord/email: sería infraestructura extra, un canal más
que mantener, y una dependencia de salida a internet para un problema que ya resuelve un monitor
encendido con alguien mirándolo.

Consecuencia de diseño, no menor: **el dashboard tiene que ser legible a tres metros de
distancia**, porque es el único canal de alerta. Nada de gráficas de líneas como panel principal.
El panel primario es un muro de estado (`Status history` / celdas de color), una fila por equipo,
una columna por servicio, verde/rojo. Un rojo se ve desde el otro lado del salón; un p95 en una
gráfica no.

Se usa Grafana Unified Alerting igual, pero solo para el estado visual de la alerta y su historia
(cuándo empezó, cuánto lleva), sin contact points. Si más adelante el evento se opera a distancia,
añadir un webhook es una hora de trabajo y no cambia nada de lo anterior.

## El punto ciego: `xss-bot`

`bot.js` (repo `sabana-corp-network`) **no escucha en ningún puerto** — el `port: 80` de
`team-xss-bot.yaml.tpl` es un placeholder que ACI exige para `ipAddress: Private`, y está
comentado como tal en la plantilla. No hay nada que sondear.

Peor: su bucle principal atrapa toda excepción y sigue girando.

```js
} catch (err) {
    // La webapp puede no estar lista en el arranque: reintentar en el próximo ciclo.
    console.error('[bot] Error en el ciclo de polling:', err.message);
}
```

`chromium.launch()` está **fuera** del bucle. Si el navegador muere —que es el modo de falla
esperado, porque los participantes le lanzan payloads a propósito— cada `visitTicket` lanza,
el catch lo traga, y el proceso gira indefinidamente sin visitar nada. El proceso nunca sale,
así que `restartPolicy: OnFailure` no dispara y el control plane reporta `Running` para siempre.
El Reto 1 está roto y todas las señales están en verde.

**Solución: health endpoint en `bot.js`.** Es la única excepción a "no tocar las imágenes", y se
justifica porque no hay alternativa externa. Un servidor HTTP mínimo (`node:http`, sin
dependencias nuevas) en el puerto 80 que ya declara la plantilla:

```json
{"ok": true, "last_visit_ts": 1754700000, "last_error": null, "browser_alive": true}
```

- `last_visit_ts`: timestamp del último ciclo completado con éxito. La sonda de Prometheus falla
  si es más viejo que `3 × BOT_VISIT_INTERVAL_SECONDS` (90s por defecto). Eso convierte "el bot
  hace su trabajo" en una señal medible, que es distinto de "el proceso vive".
- `browser_alive`: `browser.isConnected()`. Detecta el crash de Chromium directamente.

Riesgo de exposición: bajo. El endpoint solo es alcanzable desde `snet-teamN` (su propio equipo)
y desde el túnel de ese equipo; no revela flags ni el `BOT_SECRET`; y un servicio de salud en la
red corporativa encaja con el ruido ambiental del escenario. Aun así, no debe reflejar contenido
de tickets ni cookies.

Cambio complementario recomendado en el mismo PR (independiente del monitoreo, pero es el bug que
el monitoreo va a destapar): mover `chromium.launch()` dentro del bucle con relanzado si
`isConnected()` es falso.

## Inventario de sondas

Sonda `tcp_connect` salvo donde diga otra cosa. Los decoys se sondean en su puerto principal
únicamente (son ruido del escenario; que estén arriba importa, medir cada puerto no).

**Por equipo** (`snet-teamN`, `10.60.N.0/24`), ×20:

| Servicio | Puerto | Sonda |
|---|---|---|
| `database` | 3306 | `tcp_connect` (sin auth — no autenticar contra la DB del reto) |
| `webapp` | 80 | `http_2xx` a `/` (acepta 200/302) |
| `linux-server` | 22 | `ssh_banner` |
| `xss-bot` | 80 | `http_2xx` a `/health` + frescura de `last_visit_ts` |

**DMZ compartida** (`snet-dmz-shared`, `10.50.0.0/24`):

| Servicio | Puerto | Sonda |
|---|---|---|
| `dmz-filesrv` | 8080 | `http_2xx` |
| `dmz-parking` | 8080 | `http_2xx` |
| `dmz-decoy-printer` | 80 | `tcp_connect` |
| `dmz-decoy-nas` | 445 | `tcp_connect` |
| `dmz-decoy-legacy-web` | 80 | `tcp_connect` |
| `dmz-decoy-database` | 3306 | `tcp_connect` |
| `dmz-decoy-camera` | 554 | `tcp_connect` |
| `dmz-decoy-backup` | 873 | `tcp_connect` |
| `dmz-decoy-admin` | 8443 | `tcp_connect` |
| `dmz-decoy-ftp` | 21 | `tcp_connect` |
| `dmz-decoy-monitor` | 3000 | `tcp_connect` |
| `dmz-decoy-git` | 9418 | `tcp_connect` |
| `dmz-decoy-mail` | 25 | `tcp_connect` |

**VMs:**

| Host | Sonda |
|---|---|
| `vm-wiki` (`snet-dmz-vm`) | `http_2xx` a `:80`; además `docker compose ps` vía `az vm run-command` en el script de targets |
| `vm-wg-gateway` (`snet-wg-gateway`) | `wg show wg0` vía `az vm run-command`: número de peers y antigüedad del último handshake |
| `vm-monitor` | `node_exporter` local (esta sí es nuestra, aquí un agente no es superficie de ataque) |

Intervalo de scrape: 15s. Con ~95 targets y sondas TCP eso es carga despreciable para una D2s_v7.

## Alertas

Pocas y accionables. Cada una debe tener una acción obvia asociada; si no la tiene, es un panel,
no una alerta.

| Alerta | Condición | Severidad | Acción |
|---|---|---|---|
| `ServicioCaido` | `probe_success == 0` por >60s | crítica | `restore` del servicio |
| `EdificioCaido` | los 4 servicios de un `team` caídos | crítica | revisar la subred/el pool de IPs del equipo, no los contenedores uno a uno |
| `CrashLoop` | `restartCount` sube ≥3 en 10 min | crítica | mirar logs **antes** de reiniciar |
| `BotColgado` | `last_visit_ts` más viejo que 90s, o `browser_alive == false` | crítica | reiniciar `teamN-xss-bot` |
| `DerivaDeIP` | la IP inyectada en un dependiente ≠ IP actual de su dependencia | crítica | `restore` del dependiente (ver abajo) |
| `DMZDegradada` | cualquier servicio de DMZ caído | crítica | afecta a **todos** los equipos, prioridad máxima |
| `DecoyCaido` | un decoy caído >5 min | baja | cosmético, no bloquea ningún reto |
| `GatewaySinHandshakes` | 0 handshakes en 5 min con peers configurados | crítica | nadie puede entrar al lab |
| `DnsCaido` | sonda TCP/UDP 53 contra `10.10.0.4` falla | media | nadie resuelve nombres, pero ningún reto se cae (env vars siguen en IP — ver `docs/plans/internal-dns.md` "Resiliencia") |

### La alerta que no existe en ningún stack estándar: `DerivaDeIP`

`deploy_team` resuelve la falta de DNS leyendo la IP de la dependencia y **horneándola con `sed`**
en el YAML del dependiente antes de desplegarlo: `webapp` lleva dentro la IP de `database`,
`xss-bot` la de `webapp`. (El wiki vive ahora en una VM con docker-compose, donde la resolución
de nombres entre servicios es nativa.)

Consecuencia: **recrear un container group puede romper en silencio a sus dependientes.** Si
`team7-database` se recrea y toma otra IP, `team7-webapp` sigue Running, sigue respondiendo 200 en
`/`, y falla solo al tocar la base — un fallo parcial que ninguna sonda de disponibilidad detecta
y que se ve verde en el muro.

Por eso el script de targets compara, para cada dependiente, la IP que tiene inyectada
(`az container show --query "containers[0].environmentVariables"` o el YAML generado en
`yamls/generated/`) contra la IP actual de su dependencia, y exporta
`sabana_ip_drift{team,service} = 0|1`. Es la alerta más específica de esta arquitectura y la
única que no sale gratis de Prometheus.

El DNS interno (`docs/plans/internal-dns.md`, implementado) **no reemplaza esta alerta** —
decisión deliberada de ese plan: las env vars de los retos se quedan en IP a propósito, así que
`webapp` puede seguir con la IP vieja de `database` aunque el DNS ya sepa la nueva. `DerivaDeIP`
ahora tiene una hermana barata de calcular con el mismo mecanismo: comparar el registro DNS
(`dns-check <fqdn>`) contra la IP real de Azure — detecta cuándo la *zona local* quedó desincronizada,
no cuándo un contenedor quedó con la IP vieja horneada (son dos fallos distintos, con la misma
forma).

## Observar no es restaurar: subcomandos `restore`

Un dashboard que detecta pero no arregla deja al operador improvisando `az container create` a
mano durante el evento. Falta en `lab-azure.sh`:

```bash
./lab-azure.sh restore team <N> <servicio>   # database | webapp | linux-server | xss-bot
./lab-azure.sh restore dmz <servicio>
```

Semántica, en orden:

1. `az container restart` si el grupo existe y no está en crash loop (rápido, conserva la IP).
2. Si no existe o el restart falla: regenerar el YAML y `az container create` (esto **puede**
   cambiar la IP).
3. **Siempre, al final: re-resolver e inyectar las IPs de las dependencias hacia abajo.** Restaurar
   `database` implica redesplegar `webapp`; restaurar `webapp` implica redesplegar `xss-bot`. Este
   paso es lo que hace que el comando sea correcto y no solo cómodo, y es la contraparte directa
   de la alerta `DerivaDeIP`.

Reutiliza `deploy_team_workload` y la lógica de inyección de IP que ya existen; no es código nuevo,
es exponer lo que ya hace `add-team` a nivel de un solo servicio.

## Acceso

Grafana en `10.99.0.x:3000`, **sin IP pública**. Se llega por el túnel admin de WireGuard, que ya
tiene `AllowedIPs = 10.0.0.0/8` y por tanto cubre `snet-mgmt` sin tocar la config del gateway.
Los túneles de equipo no la alcanzan: sus `iptables` en `vm-wg-gateway` solo permiten su propia
`snet-teamN` + las dos DMZ (validado end-to-end el 2026-08-08, ver
`docs/plans/wireguard-vpn-gateway.md`).

Puede hacer falta una regla `FORWARD` explícita en el gateway para `admin → 10.99.0.0/24` si el
`iptables` del admin enumera subredes en vez de permitir `10.0.0.0/8` a secas — verificar contra
la implementación real de `add-peer.sh.tpl` al implementar F1.

## Costo y cuota

| | vCPU |
|---|---|
| `vm-wiki` (D2s_v7) | 2 |
| `vm-wg-gateway` (D2s_v7) | 2 |
| `vm-monitor` (D2s_v7) | 2 |
| **Total** | **6 / 10** |

Cuota verificada el 2026-08-09: `Total Regional vCPUs` 10, `Standard Dsv7 Family vCPUs` 10, 0 en
uso con el lab abajo. Quedan 4 vCPU de margen. Los ~93 container groups de ACI no consumen cuota
de VM.

D2s_v7 (2 vCPU / 8 GB) sobra para Prometheus con ~95 targets a 15s y una retención de días. Si
se añade Loki en F4, revisar disco, no CPU.

## Fases

### F1 — Stack base y descubrimiento

- Subcomando `deploy-monitor-vm` en `lab-azure.sh`: `vm-monitor` D2s_v7 en `snet-mgmt`, sin IP
  pública, managed identity con `Reader` sobre el RG. Mismo patrón que `deploy-wiki-vm`.
- cloud-init + `docker-compose`: `prometheus`, `blackbox_exporter`, `grafana`, `node_exporter`.
  Plantillas en `yamls/monitor/`, coherente con `yamls/wg-gateway/`.
- `gen-targets.sh` + systemd timer (60s) → `file_sd` con los labels `job`/`team`/`service`.
- Dashboard "Muro de equipos": fila por equipo, columna por servicio, verde/rojo, legible a tres
  metros. Un segundo dashboard para DMZ.
- Provisioning de datasource y dashboards como código (`grafana/provisioning/`), no clicks — el
  stack tiene que sobrevivir un `down`/`up` del RG.

### F2 — Reglas de alerta

- Las 8 reglas de la tabla en Grafana Unified Alerting, sin contact points.
- `sabana_ip_drift` en `gen-targets.sh` (textfile collector) y su regla.
- Panel de alertas activas, ordenado por severidad, en el mismo muro.

### F3 — `restore` en `lab-azure.sh`

- `restore team <N> <servicio>` y `restore dmz <servicio>` con la semántica de 3 pasos de arriba.
- Reutilizar `deploy_team_workload` y la inyección de IP existente.
- Enlazar el comando exacto desde la descripción de cada alerta en Grafana (el operador copia y
  pega, no recuerda la sintaxis a las 2am).

### F4 — Logs

- Diagnostics de ACI → Log Analytics Workspace en el mismo RG (nativo, no requiere agente en el
  contenedor; el volumen de un evento de horas es barato).
- Datasource Azure Monitor en Grafana → los logs del contenedor caído a un click del panel rojo.
- Alternativa considerada y descartada: Promtail/Loki. No puede leer los logs de un container
  group de ACI sin un sidecar, que es justamente lo que este plan evita.

**F1 y F2 son el mínimo útil.** F3 es lo que convierte el plan en operable durante el evento.
F4 es diagnóstico post-mortem y puede quedar para después si el tiempo aprieta.

## Riesgos y cosas a vigilar

- **La managed identity es el activo más valioso de `snet-mgmt`.** Un `Reader` sobre el RG expone
  la topología completa del lab. Hoy, dentro de la VNet, cualquier subred alcanza a `snet-mgmt`
  (Azure enruta entre subredes de la misma VNet y no hay un solo NSG creado). El gateway VPN
  bloquea a los equipos, pero no protege contra un pivote *dentro* de la VNet. Esto sube la
  prioridad de `docs/plans/network-segmentation-nsgs.md`, al menos la regla deny
  `snet-team*` → `snet-mgmt`. Alcance mínimo: `Reader` sobre el RG, nunca sobre la suscripción.
- **Rate limits del control plane.** Un `az container list` de todo el RG cada 60s es una llamada;
  una llamada por container group serían 93 y ARM las va a estrangular. No degradar el script a
  un bucle de `az container show` "para tener más detalle".
- **No confundir `vm-monitor` con `dmz-decoy-monitor`.** Nombres, labels de Prometheus y títulos
  de dashboard tienen que dejar claro cuál es cuál; el decoy expone 3000/9090 precisamente para
  parecer esto.
- **La sonda no debe ser una pista para el CTF.** `tcp_connect` contra el `database` está bien;
  no autenticar. Nada de sondas que dejen rastro en los logs de un reto de forma que confunda al
  participante (o peor, que le regale la existencia de la red de gestión).
- **`down` borra el RG entero**, monitor incluido. Invariante del proyecto (`CLAUDE.md`),
  respetarlo: nada del stack fuera del RG del lab, y toda la config de Grafana provisionada como
  código para poder reconstruirla.
- **El health endpoint del `xss-bot` es un cambio en `sabana-corp-network`**, no en este repo.
  Requiere reconstruir y republicar `maosuarez/sabana-lab-xss-bot:latest`, y coordinarse con el
  ciclo de despliegue de ese repo.
- **La delegación de `snet-dmz-shared` a ACI no aplica a `snet-mgmt`.** `snet-mgmt` no está
  delegada, por eso admite VM. No delegarla nunca a `Microsoft.ContainerInstance/containerGroups`
  o `vm-monitor` deja de poder existir ahí (mismo problema que forzó `snet-dmz-vm`, ver
  `docs/plans/wiki-on-vm.md`).

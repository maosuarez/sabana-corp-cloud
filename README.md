# Sabana Corp: CTF infraestructura como código

Infraestructura automática para **Sabana Corp**, el Capture The Flag de la Semana de Ingeniería de la Universidad de la Sabana. Todos los servicios corren en **Azure Container Instances** dentro de una VNet privada sin acceso directo a internet — se alcanza tras autenticarse en un portal cautivo y conectar por VPN (WireGuard, validado end-to-end 2026-08-08).

## Estado actual

**Implementado y probado (agosto 2026):**
- Infraestructura base: Resource Group, VNet (`10.0.0.0/8`), 6 subredes (delegadas/sin delegar según sea necesario)
- 13 contenedores DMZ compartidos en ACI: filesrv, parking, 11 decoys — accesibles desde cualquier equipo
- Wiki + wiki-db en VM (`vm-wiki`, snet-dmz-vm, docker-compose) — validado end-to-end 2026-08-08
- Contenedores por equipo: database, webapp, linux-server, xss-bot (4 contenedores × N equipos)
- Cada contenedor recibe su propia IP privada dentro de su subred
- Secretos y flags inyectados vía variables de entorno (mismo conjunto para todos los equipos, como requiere CTFd)
- Resolución automática de IPs entre contenedores dependientes
- **Gateway WireGuard** (`vm-wg-gateway`, snet-wg-gateway, IP pública, UDP 51820) con aislamiento de acceso por peer vía `iptables` — validado end-to-end 2026-08-08
- **DNS interno** (dnsmasq en `vm-wg-gateway`, dominio `sabanacorp.internal`): nombres para equipos/DMZ resolubles desde contenedores ACI y desde el PC del participante por el túnel VPN — validado end-to-end 2026-08-10. Ver `docs/plans/internal-dns.md`
- **CTFd** (flags y scoreboard en VM `vm-ctfd`, snet-dmz-vm, docker-compose: nginx + gunicorn + MariaDB + Redis) — validado end-to-end 2026-08-11. Challenges se cargan `hidden` por defecto; publicar con `CTFD_SEED_PUBLISH=1` o `seed_challenges.py --publish`. Ver `docs/plans/ctfd-deployment.md`
- **Observabilidad** (Prometheus + Grafana en VM `vm-monitor`, snet-mgmt, descubrimiento vivo vía `az container list`, 2 dashboards, 7 reglas de alerta) — validado end-to-end 2026-08-10. Ver `docs/plans/observability-monitoring.md`

**No implementado:**
- **Provisioner** (aprovisionamiento automático de recursos de equipo): no tiene imagen/Dockerfile en ningún repo todavía, solo documentado en la arquitectura
- **Segmentación NSG**: diseño completado en `docs/plans/network-segmentation-nsgs.md`, no aplicado (hoy todas las subredes se ven entre sí sin restricción dentro de la VNet)
- **Persistencia persistente de wiki en VM**: los volúmenes de docker-compose (`wiki_mariadb_data`, `wiki_bookstack_config`) usan discos locales de la VM. Si la VM se destruye, se pierden — para un lab persistente, implementar Azure File Share

La infraestructura base fue desplegada para prueba el 2026-08-01/02, validada exitosamente, y luego destruida. El **2026-08-08 se probó end-to-end el despliegue completo de infraestructura + equipos** (`up`, `deploy-dmz`, `deploy-wiki-vm`, `deploy-wg-gateway`, `add-team`/`add-team-range` y el flujo VPN). El **2026-08-10 se validaron DNS interno y observabilidad** (`deploy-monitor-vm`). El **2026-08-11 se validó CTFd** (`deploy-ctfd-vm`). Lo único sin probar es lo que aún no existe: Provisioner y los planes de `docs/plans/` marcados como diseño.

## Requisitos previos

```bash
# Instalados y funcionales:
az CLI                                    # Azure CLI (az login contra Azure for Students)
envsubst                                  # Paquete gettext-base
docker login                              # Credenciales Docker Hub configuradas

# Exportar variables de entorno:
export DOCKERHUB_USER="tu_usuario"
export DOCKERHUB_TOKEN="access_token"     # Docker Hub → Account Settings → Security → New Access Token

# Archivos:
cp yamls/.env.secrets.example yamls/.env.secrets
# Editar yamls/.env.secrets con los flags/secretos reales
```

**Nota sobre suscripción**: el script asume `az login` contra "Azure for Students" (tenant Universidad de la Sabana). Si usas otra suscripción, edita `RG`, `LOCATION` y `VNET` en `lab-azure.sh`.

## Flujo de uso

**Infraestructura base (obligatorio):**
```bash
./lab-azure.sh up                    # Crea RG, VNet, 6 subredes base, delega snet-dmz-shared a ACI
```

**DMZ compartida:**
```bash
./lab-azure.sh deploy-dmz            # Despliega 13 contenedores en snet-dmz-shared (filesrv, parking, decoys)
./lab-azure.sh deploy-wiki-vm        # Despliega vm-wiki en snet-dmz-vm con wiki+wiki-db via docker-compose
./lab-azure.sh deploy-ctfd-vm        # Despliega vm-ctfd en snet-dmz-vm con CTFd (nginx+gunicorn+MariaDB+Redis)
                                     # Carga /setup y challenges sin clicks manuales, pero quedan
                                     # 'hidden' por defecto -- exporta CTFD_SEED_PUBLISH=1 antes del
                                     # comando para publicarlos de una (o corre seed_challenges.py
                                     # --publish contra el vm-ctfd ya desplegado, sin recrearlo)
                                     # Validado end-to-end 2026-08-11 (ver docs/plans/ctfd-deployment.md,
                                     # "Runbook del día del evento" para los comandos exactos)
```

**Gateway VPN (opcional pero necesario si se requiere acceso remoto):**
```bash
./lab-azure.sh deploy-wg-gateway     # Crea vm-wg-gateway (IP pública, WireGuard UDP 51820)
                                     # + genera client admin en yamls/generated/wg-clients/admin.conf
                                     # Validado end-to-end 2026-08-08 (ver docs/plans/wireguard-vpn-gateway.md)
```

**Observabilidad (opcional):**
```bash
./lab-azure.sh deploy-monitor-vm     # Despliega vm-monitor en snet-mgmt con Prometheus+Grafana+alertas
                                     # Descubre servicios vía 'az container list', 2 dashboards,
                                     # 7 reglas de alerta (sin contact points, requiere config manual)
                                     # Validado end-to-end 2026-08-10 (ver docs/plans/observability-monitoring.md)
```

**Equipos (secuencial o paralelo):**
```bash
# Opción 1: agregar equipos uno por uno
./lab-azure.sh add-team 1            # Crea snet-team1, despliega 4 contenedores, genera peer WireGuard
./lab-azure.sh add-team 2            # Repite para cada equipo adicional
./lab-azure.sh add-team 3

# Opción 2: agregar múltiples equipos en un comando
./lab-azure.sh add-team-range 1 20   # Despliega equipos 1..20 (secuencial, se detiene en error)

# Opción 3: agregar equipos en paralelo (acelera la creación)
./lab-azure.sh add-team-range 1 20 4 # Despliega equipos 1..20 con 4 en paralelo
                                     # Subnets se crean secuenciales (evita 409 de Azure),
                                     # contenedores se despliegan en paralelo,
                                     # peers WireGuard se crean secuenciales
                                     # (ver CLAUDE.md "Decisión de diseño: paralelismo en add-team-range")
```

**Backfill de peer WireGuard (si un equipo fue desplegado antes del gateway):**
```bash
./lab-azure.sh wg-team-peer 1        # Genera/aplica solo el peer WireGuard de team1
                                     # Útil para equipos que se crearon antes de deploy-wg-gateway
```

**DNS interno (dnsmasq en vm-wg-gateway, ver `docs/plans/internal-dns.md`):**
```bash
./lab-azure.sh dns-sync              # Empuja el estado local (yamls/generated/dns/*.hosts) al
                                     # gateway en una sola invocación -- ya se llama sola al
                                     # final de deploy-dmz/add-team/deploy-wiki-vm
./lab-azure.sh dns-sync --from-azure # Reconstruye TODA la zona desde 'az container list'
                                     # (comando de reparación / chequeo pre-evento)
./lab-azure.sh dns-check <fqdn>      # Resuelve <fqdn> desde el gateway y lo compara con la IP
                                     # real de Azure
```

**Estado y pruebas:**
```bash
./lab-azure.sh status                # Muestra estado de DMZ, DMZ-VM, gateway WireGuard, equipos
./lab-azure.sh test [N]              # Atajo: up + deploy-dmz + add-team N (N=1 por defecto)
                                     # Útil para pruebas rápidas sin gateway VPN
```

**Destrucción:**
```bash
./lab-azure.sh down                  # Destruye todo (borra el Resource Group completo)
                                     # Pide confirmación explícita antes de borrar
```

## Estructura de archivos

### `CLAUDE.md`
Guía interna para Claude Code (agente de IA). Contiene:
- Decisiones de diseño justificadas (1 YAML = 1 contenedor, xss-bot aislado por equipo, plantillas + generadores)
- Arquitectura de red objetivo y pendientes
- Comandos principales y notas de costo
- Referencias a la implementación en `lab-azure.sh` y `yamls/`

No es documentación pública — es guía de contexto para mantenedores IA.

### `lab-azure.sh`
Orquestación completa del ciclo de vida: crear/desplegar/destruir infraestructura.
- Define variables (`RG`, `VNET`, `LOCATION`)
- Comandos principales:
  - `up` — infraestructura base (RG, VNet, subredes, delegaciones)
  - `deploy-dmz` — 13 contenedores DMZ en ACI
  - `deploy-wiki-vm` — VM con wiki+wiki-db (docker-compose)
  - `deploy-ctfd-vm` — VM con CTFd + MariaDB + Redis (docker-compose)
  - `deploy-wg-gateway` — VM con WireGuard + peer admin + dnsmasq
  - `deploy-monitor-vm` — VM con Prometheus + Grafana + alertas (descubrimiento vivo)
  - `add-team <N>` — crea equipo N (subred + 4 contenedores + peer WireGuard)
  - `add-team-range <inicio> <fin> [paralelismo]` — crea múltiples equipos en paralelo (opcional)
  - `wg-team-peer <N>` — genera solo el peer WireGuard de equipo N (backfill)
  - `dns-sync [--from-azure]` — sincroniza el DNS interno con el gateway (ver `docs/plans/internal-dns.md`)
  - `dns-check <fqdn>` — resuelve un nombre desde el gateway y lo compara con Azure
  - `test [N]` — atajo para pruebas: up + deploy-dmz + add-team N
  - `status` — muestra estado de toda la infraestructura
  - `down` — destruye todo
- Llama a los generadores de `yamls/` e inyecta IPs resueltas en los YAML antes de desplegar
- Maneja reintentos y esperas para que ACI asigne IP privada (notoriamente lento cuando VNet está integrada)
- Implementa paralelismo configurable en `add-team-range`: subnets secuenciales (evita 409 de Azure), contenedores paralelos (acelera), peers WireGuard secuenciales (evita corrupción de config compartida)

Ver comentarios en líneas 1-40 del script para contexto histórico (primer prototipo vs. diseño actual de 1-YAML-por-contenedor).

### `yamls/`
Plantillas y generadores para contenedores, VMs y clientes VPN.
- **`templates/*.yaml.tpl`**: plantillas con variables `${...}` (TEAM, DOCKERHUB_USER, DOCKERHUB_TOKEN, SUBSCRIPTION_ID, RESOURCE_GROUP, VNET)
  - `team-*.yaml.tpl` (database, webapp, linux-server, xss-bot) — una por equipo, agnósticas al número vía `${TEAM}`
  - `dmz-*.yaml.tpl` (filesrv, parking, 11 decoy-*) — un solo despliegue compartido en ACI
- **`generate-team.sh <N>` / `generate-dmz.sh`**: resuelven variables sobre plantillas → `generated/*.yaml` (gitignored, contiene secretos)
- **`.env.secrets`** (gitignored, plantilla en `.env.secrets.example`): FLAGS, contraseñas de BD, JWT_SIGNING_SECRET — compartidos por todos los equipos (por diseño de CTFd)
- **`generated/`** (gitignored): salida de los generadores, YAML con secretos ya resueltos, cliente WireGuard .conf
- **`wiki-vm/`**: cloud-init y docker-compose para la VM wiki (validado end-to-end 2026-08-08, ver `docs/plans/wiki-on-vm.md`)
- **`ctfd-vm/`** + **`templates/ctfd-compose.yml.tpl`** + **`generate-ctfd-vm.sh`**: cloud-init, docker-compose adaptado de `../sabana-corp-CTFd/docker-compose.prod.yml` (nginx + ctfd/gunicorn + MariaDB + Redis) para VM en `snet-dmz-vm`. Primer arranque sin clicks: `generate-ctfd-vm.sh` vendorea `../sabana-corp-CTFd/scripts/seed_setup.py` a `generated/ctfd/seed/`, que `lab-azure.sh` ejecuta dentro del contenedor para completar `/setup` y cargar challenges. Secretos vía bloque `CTFD_*` en `.env.secrets`. Validado end-to-end 2026-08-11, ver `docs/plans/ctfd-deployment.md`
- **`monitor/`** + **`templates/monitor-compose.yml.tpl`** / **`templates/monitor-gen-targets.service.tpl`** + **`generate-monitor.sh`**: cloud-init, docker-compose (Prometheus + blackbox_exporter + Grafana + node_exporter), configuración de sondeo, y provisioning de Grafana (datasources, dashboards, reglas de alerta). Descubrimiento vivo de servicios vía `az container list`; `remote/gen_targets.py` genera targets + métricas con paralelismo. Validado end-to-end 2026-08-10, ver `docs/plans/observability-monitoring.md`
- **`wg-gateway/`**: cloud-init, scripts remotos, y plantillas para el gateway WireGuard VM (validado end-to-end 2026-08-08, ver `docs/plans/wireguard-vpn-gateway.md`). Incluye `remote/apply-dns.sh.tpl` (instala zonas DNS en dnsmasq — ver `docs/plans/internal-dns.md`)
- **`generate-wg-client.sh`**: genera `.conf` + `-README.md` para clientes WireGuard (peers de equipos + admin)
- **`generate-dns-hosts.sh`**: genera bloques de zona DNS (`generated/dns/*.hosts`) desde IPs conocidas o desde `az container list` — ver `docs/plans/internal-dns.md`

Ver `yamls/README.md` para detalles de orden de despliegue, resolución de IPs dependientes, y generación de archivos.

### `docs/plans/`
Documentación de decisiones de diseño e implementación:
- **`wiki-on-vm.md`**: por qué BookStack no corre en ACI (s6-overlay/PID1), plan e implementación de wiki+wiki-db en una VM con docker-compose (validado end-to-end 2026-08-08, cuota de VM desbloqueada tras upgrade a pay-as-you-go)
- **`wireguard-vpn-gateway.md`**: diseño e implementación del gateway WireGuard (validado end-to-end 2026-08-08), incluyendo aislamiento de acceso por peer vía `iptables`
- **`internal-dns.md`**: DNS interno del lab con dnsmasq en `vm-wg-gateway`, FQDN para equipos/DMZ resolubles también desde el PC del participante por el túnel — implementado y validado end-to-end 2026-08-10
- **`ctfd-deployment.md`**: diseño e implementación de CTFd en `vm-ctfd` (flags y scoreboard), decisiones de despliegue (VM vs. ACI/Web App), automatización de challenges via `seed_setup.py`, runbook del evento — validado end-to-end 2026-08-11
- **`observability-monitoring.md`**: Prometheus + Grafana para el staff (descubrimiento vivo, 2 dashboards, 7 reglas de alerta) — F1+F2 implementados y validados end-to-end 2026-08-10; F3/F4 (restore/logs) siguen en diseño
- **`network-segmentation-nsgs.md`**: matriz de reglas NSG propuesta para aislar equipos entre sí y de la DMZ (diseño completado, no implementado), incluyendo notas de rollout

## Costos

Suscripción: **Azure for Students** (crédito fijo, no pay-as-you-go).

```bash
# Verificar consumo:
az consumption usage list --output table
```

Nota: `az consumption usage list` suele devolver `403 AuthorizationFailed` en suscripciones Azure for Students (limitación conocida, no es un error de config). Ver saldo en el portal: portal.azure.com → Suscripciones → Azure for Students → Cost analysis o widget de crédito restante.

**Estimado de ejecución:**
- ACI se factura por CPU-segundo + GB-segundo (según la imagen, típicamente 1 vCPU / 1 GB)
- 20 contenedores × ~5 minutos de despliegue ≈ ~1500 CPU-segundos, costo negligible
- Para un evento de 4 horas: 20 contenedores × 4h × 60min/h × 1 vCPU ≈ $1–3 (estimado grueso, con Network Egress los costos suben si hay bandwidth alto)
- Destruir con `down` libera todo al momento — sin cargos mientras no corre

## Limitaciones y pendientes

Documentado en detalle en `CLAUDE.md` y `yamls/README.md`. Resumen:

1. **Persistencia de wiki en VM limitada**: los volúmenes de docker-compose usan discos locales de la VM. Destruir la VM pierde datos — para un lab persistente, implementar Azure File Share
2. **Sin Provisioner**: no tiene imagen/Dockerfile en ningún repo todavía; es el único servicio de la arquitectura original sin implementar
3. **Sin segmentación de red (NSG)**: hoy un equipo puede alcanzar otros equipos (incluso dentro de la VNet sin pasar por VPN) — diseño completado pero no aplicado (ver `docs/plans/network-segmentation-nsgs.md`)
4. **Sin validación de NSG asimétricos**: los NSGs aplicados hoy (solo al gateway WireGuard) son básicos; control de acceso más fino (equipos aislados, DMZ sin iniciar conexiones) requiere más validación

## Contribuir

Cualquier cambio en `lab-azure.sh`, `yamls/templates`, o arquitectura de red debe:
1. Ser documentado en este README (cambios significativos) o en `CLAUDE.md` (decisiones de diseño)
2. Testear contra Azure (no especular) — las plataformas (ACI, VNet, NSG) tienen comportamientos sorpresivos
3. Destruir completamente (`down`) después de validar, a menos que haya una razón para mantener la infraestructura viva

Para instrucciones internas dirigidas a Claude (agente de IA), ver `CLAUDE.md`.

## Referencias

- **Repositorio de imágenes DMZ**: https://github.com/Anacha1304/Semana-Ingenier-a (Dockerfile, compose.yml, contenido de retos)
- **Repositorio de imágenes team**: https://github.com/maosuarez/sabana-corp-network (Dockerfile, aplicaciones de equipo)
- **Documentación de Azure Container Instances**: https://learn.microsoft.com/en-us/azure/container-instances/

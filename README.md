# Sabana Corp: CTF infraestructura como código

Infraestructura automática para **Sabana Corp**, el Capture The Flag de la Semana de Ingeniería de la Universidad de la Sabana. Todos los servicios corren en **Azure Container Instances** dentro de una VNet privada sin acceso directo a internet — se alcanza tras autenticarse en un portal cautivo y conectar por VPN (el conector VPN no está implementado todavía).

## Estado actual

**Implementado y probado (agosto 2026):**
- Infraestructura base: Resource Group, VNet (`10.0.0.0/8`), 6 subredes (delegadas/sin delegar según sea necesario)
- 15 contenedores DMZ compartidos: filesrv, wiki, parking, wiki-db, 11 decoys — accesibles desde cualquier equipo
- Contenedores por equipo: database, webapp, linux-server, xss-bot (4 contenedores × N equipos)
- Cada contenedor recibe su propia IP privada dentro de su subred
- Secretos y flags inyectados vía variables de entorno (mismo conjunto para todos los equipos, como requiere CTFd)
- Resolución automática de IPs entre contenedores dependientes

**No implementado / bloqueado:**
- **Wiki en VM**: scripts escritos pero nunca ejecutados — bloqueado porque Azure for Students no permite pedir aumento de quota de VM (confirmado 2026-08-02, ni self-service ni por ticket de soporte)
- **CTFd, Provisioner, Monitor**: no están en ningún repo, solo documentados en la arquitectura
- **Segmentación NSG**: diseño completado en `docs/plans/network-segmentation-nsgs.md`, no aplicado (hoy todas las subredes se ven entre sí sin restricción)
- **Conector VPN**: arquitectura pendiente de decidir
- **Persistencia de wiki**: BookStack en ACI pierde su configuración si el contenedor se reinicia (aceptable para un evento de un día, pero pendiente de validar Azure File Share si se necesita)

La infraestructura fue desplegada para prueba, validada exitosamente y luego destruida completamente el 2026-08-02 con `./lab-azure.sh down`.

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

```bash
# Crear infraestructura base (RG, VNet, subredes, delegaciones)
./lab-azure.sh up

# Desplegar los 15 contenedores DMZ compartidos
./lab-azure.sh deploy-dmz

# Crear una subred para team1 y desplegar sus 4 contenedores
./lab-azure.sh add-team 1

# Repetir para cada equipo adicional
./lab-azure.sh add-team 2
./lab-azure.sh add-team 3
# ... etc.

# Ver estado de todos los containers groups (nombre, estado, IP privada)
./lab-azure.sh status

# Destruir todo (pide confirmación "si")
./lab-azure.sh down
```

**Atajo para pruebas rápidas:**
```bash
./lab-azure.sh test [N]    # up + deploy-dmz + add-team N (N=1 si se omite)
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
- Funciones: `require_dockerhub_env()`, `wait_for_ip()`, `deploy_container()`, y comandos principales (`up`, `deploy-dmz`, `add-team`, `test`, `status`, `down`)
- Llama a los generadores de `yamls/` e inyecta IPs resueltas en los YAML antes de desplegar
- Maneja reintentos y esperas para que ACI asigne IP privada (notoriamente lento cuando VNet está integrada)

Ver comentarios en la línea 1-40 del script para contexto histórico (primer prototipo vs. diseño actual de 1-YAML-por-contenedor).

### `yamls/`
Plantillas y generadores para los contenedores.
- **`templates/*.yaml.tpl`**: plantillas con variables `${...}` (TEAM, DOCKERHUB_USER, DOCKERHUB_TOKEN, SUBSCRIPTION_ID, RESOURCE_GROUP, VNET)
  - `team-*.yaml.tpl` (database, webapp, linux-server, xss-bot) — una por equipo, agnósticas al número vía `${TEAM}`
  - `dmz-*.yaml.tpl` (filesrv, wiki-db, wiki, parking, 11 decoy-*) — un solo despliegue compartido
- **`generate-team.sh <N>` / `generate-dmz.sh`**: resuelven variables sobre plantillas → `generated/*.yaml` (gitignored, contiene secretos)
- **`.env.secrets`** (gitignored, plantilla en `.env.secrets.example`): FLAGS, contraseñas de BD, JWT_SIGNING_SECRET — compartidos por todos los equipos (por diseño de CTFd)
- **`generated/`** (gitignored): salida de los generadores, YAML con secretos ya resueltos
- **`wiki-vm-compose.yml.tpl` / `generate-wiki-vm.sh` / `wiki-vm/`**: plan no probado para wiki en VM (bloqueado en quota)

Ver `yamls/README.md` para detalles de orden de despliegue, resolución de IPs dependientes, y pendientes conocidos (persistencia de wiki, CTFd/Provisioner/Monitor no generados).

### `docs/plans/`
Diseños de características futuras:
- **`wiki-on-vm.md`**: por qué BookStack no corre en ACI (s6-overlay/PID1), plan para mover wiki+wiki-db a una VM con docker-compose, y bloqueo actual (Azure for Students no elegible para aumentar quota de VM)
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

1. **Sin persistencia de wiki entre reinicios**: BookStack en ACI perdería su config si se reinicia. Para un evento de un día está bien; para un lab persistente, implementar Azure File Share o mover a VM
2. **Sin segmentación de red (NSG)**: hoy un equipo puede alcanzar otros equipos — diseño completado pero no aplicado (ver `docs/plans/network-segmentation-nsgs.md`)
3. **Sin VPN**: acceso interno solo — falta el conector VPN hacia internet
4. **Sin CTFd/Provisioner/Monitor**: no implementados, solo documentados en la arquitectura
5. **Sin validación de ACI + capability NET_ADMIN para WireGuard**: plan alternativo a VM si se necesita gateway VPN en ACI (sin confirmar soporte)

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

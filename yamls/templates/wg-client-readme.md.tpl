# Acceso VPN — ${PEER_NAME}

Generado por `yamls/generate-wg-client.sh` -- no editar a mano, se regenera. Ver
`docs/plans/internal-dns.md` para el detalle completo del DNS interno del lab.

## 1. Importar el túnel

Archivo: `${PEER_NAME}.conf` (en esta misma carpeta).

- **Windows/macOS (app oficial de WireGuard)**: "Import tunnel(s) from file" → selecciona el `.conf`.
- **Linux**: `sudo wg-quick up ./${PEER_NAME}.conf` (o importa el archivo en tu gestor de red si usa NetworkManager).
- **Android/iOS (app oficial)**: importa el `.conf` (por QR o archivo) desde la app.

## 2. Servicios de Sabana Corp

Sabana Corp usa nombres, no IPs. Con el túnel arriba, estos nombres resuelven:

${TEAM_SERVICES_BLOCK}

| Servicio (red corporativa compartida) | Nombre |
|---|---|
| File-Srv (archivos compartidos) | `filesrv.dmz.${LAB_DOMAIN}` (alias: `files.dmz.${LAB_DOMAIN}`) |
| Wiki interna (pistas) | `wiki.dmz.${LAB_DOMAIN}` (alias: `wiki-int.dmz.${LAB_DOMAIN}`) |
| Parqueadero (reto final) | `parking.dmz.${LAB_DOMAIN}` |

Hay más equipos en la red corporativa (`sabanacorp.internal`) que no están en esta tabla —
reconocimiento de red es parte del ejercicio.

## 3. Verificar que el DNS funciona

- **Windows (PowerShell)**: `Resolve-DnsName webapp.${PEER_NAME}.${LAB_DOMAIN}` — **no uses `nslookup`**,
  no respeta la regla de split-DNS (NRPT) y va a decir "no existe" aunque todo esté bien.
- **Linux**: `getent hosts webapp.${PEER_NAME}.${LAB_DOMAIN}` o `resolvectl query webapp.${PEER_NAME}.${LAB_DOMAIN}`.
- **macOS**: `dscacheutil -q host -a name webapp.${PEER_NAME}.${LAB_DOMAIN}`.

## 4. Nota para Linux/WSL

`wg-quick` puede fallar con `resolvconf: command not found` en instalaciones mínimas y en WSL2.
Solución: `sudo apt install openresolv`. Alternativa sin instalar nada: borra la línea `DNS =` del
`.conf` y usa `dig @10.200.0.1 <nombre>` cuando necesites resolver un nombre del lab.

## 5. Importante

**Que un nombre resuelva no significa que puedas alcanzarlo.** El control de acceso real está en
el gateway, no en el DNS: vas a poder ver nombres de otros equipos, pero conectarte a ellos es
exactamente lo que este CTF te reta a lograr.

## 6. Reconocimiento de red: nmap-sabana-corp

En esta misma carpeta viene `nmap-sabana-corp.mjs`: un comando sin privilegios que, con el túnel
arriba, te dice qué hay vivo en tu alcance y en qué puertos -- calculado en tiempo real, sin listas
fijas. No necesita instalación ni internet:

```bash
node nmap-sabana-corp.mjs --scan
```

Si preferís instalarlo como paquete global (recomendado hacerlo **antes** del evento, el lab no
tiene salida a internet):

```bash
npm install -g nmap-sabana-corp
nmap-sabana-corp --version   # verificacion de pre-flight
```

Los dos hacen exactamente lo mismo. Ninguno te va a mostrar banners, versiones de servicio, ni
pistas de los retos -- ver el `README.md` del paquete para el detalle completo de qué muestra y qué
no.

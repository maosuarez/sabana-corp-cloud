#!/usr/bin/env python3
"""
gen_targets.py -- corre en vm-monitor via systemd timer (gen-targets.timer, cada 60s).

Ver docs/plans/observability-monitoring.md "Decision de diseño: descubrimiento via
'az container list', no targets estaticos" y "sondeo externo (blackbox), no agentes".

CORRECCION respecto al plan original: 'az container list' NO trae 'instanceView' poblado --
limitacion de la API/CLI ya documentada en lab-azure.sh (print_container_states(), comentario
sobre 'az container show' por contenedor). Confirmado de nuevo aqui en el primer despliegue real:
con 'list' el estado y el restartCount siempre llegan vacios. El plan asumia que 'list' bastaba
para las tres cosas (IP, estado, restarts) -- no es cierto, solo la IP viene poblada por 'list'.

Por eso el estado de control plane (señal secundaria "b") se refresca por separado, con
'az container show' por contenedor, PERO no en cada tick de 60s -- eso si violaria el limite de
rate del control plane que el plan advierte evitar (93 grupos * 1/min = 93 llamadas/min).
Se refresca cada STATE_REFRESH_SECONDS (5 min por defecto, ~93 llamadas/5min = bien por debajo de
cualquier limite de ARM), paralelizado con un pool acotado, y se cachea en disco entre ticks.

Escribe tres archivos:

  - /etc/prometheus/targets/aci_targets.json
      formato file_sd de Prometheus. Cada entrada lleva su IP:puerto real en "targets" (se
      convierte en __param_target via relabel_configs en prometheus.yml) y los labels
      group/team/service/probe_module que alimentan el dashboard "Muro de equipos". Se
      reescribe en CADA tick (barato: una sola 'az container list').

  - /etc/node_exporter/textfile/sabana_drift.prom
      sabana_ip_drift (ver "La alerta que no existe en ningun stack estandar" en el plan). Se
      reescribe en cada tick -- se calcula con datos que 'list' ya trae (IP + environmentVariables
      no seguros), sin llamadas extra.

  - /etc/node_exporter/textfile/sabana_state.prom
      sabana_container_state + sabana_container_restart_count (señal secundaria "b"). Se
      reescribe en cada tick a partir del CACHE, pero el cache mismo solo se refresca contra
      Azure cada STATE_REFRESH_SECONDS.

Variable de entorno usada: RESOURCE_GROUP (fijada en gen-targets.service).

Punto ciego conocido y documentado en el plan: 'xss-bot' no tiene sonda propia todavia -- no
escucha en ningun puerto hasta que bot.js exponga /health (cambio pendiente en el repo
sabana-corp-network, fuera de alcance de este script). Su estado de control plane (Running/
restartCount) SI se reporta -- es insuficiente sola (ver la tabla del plan) pero mejor que nada.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

RG = os.environ["RESOURCE_GROUP"]
STATE_REFRESH_SECONDS = int(os.environ.get("STATE_REFRESH_SECONDS", "300"))
STATE_POOL_WORKERS = 10

TARGETS_DIR = "/etc/prometheus/targets"
TEXTFILE_DIR = "/etc/node_exporter/textfile"
TARGETS_FILE = os.path.join(TARGETS_DIR, "aci_targets.json")
DRIFT_PROM_FILE = os.path.join(TEXTFILE_DIR, "sabana_drift.prom")
STATE_PROM_FILE = os.path.join(TEXTFILE_DIR, "sabana_state.prom")
STATE_CACHE_FILE = os.path.join(TEXTFILE_DIR, ".sabana_state_cache.json")

# service (derivado del nombre del container group) -> (puerto, modulo de blackbox.yml)
# Ausente de este mapa == sin sonda blackbox (solo estado de control plane). Hoy solo aplica a
# xss-bot -- ver docstring.
SERVICE_PROBES = {
    "database": (3306, "tcp_connect"),
    "webapp": (80, "http_2xx"),
    "linux-server": (22, "ssh_banner"),
    "filesrv": (8080, "http_2xx"),
    "parking": (8080, "http_2xx"),
    "decoy-printer": (80, "tcp_connect"),
    "decoy-nas": (445, "tcp_connect"),
    "decoy-legacy-web": (80, "tcp_connect"),
    "decoy-database": (3306, "tcp_connect"),
    "decoy-camera": (554, "tcp_connect"),
    "decoy-backup": (873, "tcp_connect"),
    "decoy-admin": (8443, "tcp_connect"),
    "decoy-ftp": (21, "tcp_connect"),
    "decoy-monitor": (3000, "tcp_connect"),
    "decoy-git": (9418, "tcp_connect"),
    "decoy-mail": (25, "tcp_connect"),
    "wiki": (80, "http_2xx"),
}


def az(*args):
    out = subprocess.run(
        ["az", *args, "-o", "json"], capture_output=True, text=True, timeout=60
    )
    if out.returncode != 0:
        sys.stderr.write(out.stderr)
        return None
    try:
        return json.loads(out.stdout)
    except json.JSONDecodeError:
        return None


def classify(name):
    """nombre del container group -> (group, team, service) o None si no se reconoce."""
    m = re.match(r"^team(\d+)-(.+)$", name)
    if m:
        return "edificio", m.group(1), m.group(2)
    m = re.match(r"^dmz-decoy-(.+)$", name)
    if m:
        return "dmz-decoy", "", f"decoy-{m.group(1)}"
    m = re.match(r"^dmz-(.+)$", name)
    if m:
        return "dmz", "", m.group(1)
    return None


def env_value(env_list, key):
    for e in env_list or []:
        if e.get("name") == key:
            return e.get("value")
    return None


def atomic_write(path, content):
    d = os.path.dirname(path)
    fd, tmp = tempfile.mkstemp(dir=d)
    with os.fdopen(fd, "w") as f:
        f.write(content)
    # mkstemp crea el archivo 0600 (solo root) -- node-exporter/prometheus corren dentro de sus
    # contenedores con un UID no-root y montan estos directorios read-only, asi que sin este
    # chmod no pueden leer nada de lo que este script escribe.
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def load_state_cache():
    try:
        with open(STATE_CACHE_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def fetch_container_state(name):
    """Una llamada 'az container show' -- solo se usa desde el pool acotado de refresh_state_cache."""
    result = az(
        "container", "show", "-g", RG, "-n", name,
        "--query", "{state:instanceView.state, restarts:containers[0].instanceView.restartCount}",
    )
    if result is None:
        return name, None
    return name, result


def refresh_state_cache(names):
    """Refresca el cache de estado SOLO para los nombres cuya entrada tiene mas de
    STATE_REFRESH_SECONDS de antiguedad (o no existe todavia). Paralelizado con un pool acotado
    para no convertir esto en 93 llamadas secuenciales -- ver docstring del modulo."""
    cache = load_state_cache()
    now = time.time()
    stale = [n for n in names if now - cache.get(n, {}).get("ts", 0) >= STATE_REFRESH_SECONDS]
    if stale:
        with ThreadPoolExecutor(max_workers=STATE_POOL_WORKERS) as pool:
            for name, result in pool.map(fetch_container_state, stale):
                if result is not None:
                    cache[name] = {
                        "state": result.get("state") or "",
                        "restarts": result.get("restarts"),
                        "ts": now,
                    }
        atomic_write(STATE_CACHE_FILE, json.dumps(cache))
    return cache


def main():
    os.makedirs(TARGETS_DIR, exist_ok=True)
    os.makedirs(TEXTFILE_DIR, exist_ok=True)

    # az login --identity es idempotente (reusa el token cacheado si sigue vivo) -- no falla el
    # script si ya hay sesion.
    subprocess.run(["az", "login", "--identity"], capture_output=True, text=True)

    containers = az(
        "container", "list", "-g", RG,
        "--query",
        "[].{name:name, ip:ipAddress.ip, env:containers[0].environmentVariables}",
    ) or []

    by_name = {c["name"]: c for c in containers}

    wiki_ip_result = az("vm", "list-ip-addresses", "-g", RG, "-n", "vm-wiki") or []
    wiki_ip = None
    if wiki_ip_result:
        addrs = wiki_ip_result[0].get("virtualMachine", {}).get("network", {}).get(
            "privateIpAddresses", []
        )
        wiki_ip = addrs[0] if addrs else None

    classified = {name: classify(name) for name in by_name}
    classified = {name: cls for name, cls in classified.items() if cls is not None}

    # Estado de control plane: refresco acotado (STATE_REFRESH_SECONDS), no una llamada por
    # nombre en cada tick -- ver docstring del modulo.
    state_cache = refresh_state_cache(list(classified.keys()))

    targets = []
    drift_lines = [
        "# HELP sabana_ip_drift 1 si la IP horneada (sed) en el dependiente ya no coincide con la "
        "IP real de su dependencia -- ver docs/plans/observability-monitoring.md.",
        "# TYPE sabana_ip_drift gauge",
    ]
    state_lines = [
        "# HELP sabana_container_state Estado de control plane del container group (1=Running). "
        f"Refrescado cada {STATE_REFRESH_SECONDS}s, no en cada tick -- ver docstring del modulo.",
        "# TYPE sabana_container_state gauge",
        "# HELP sabana_container_restart_count restartCount reportado por Azure para el container 0.",
        "# TYPE sabana_container_restart_count gauge",
    ]

    for name, cls in classified.items():
        group, team, service = cls
        c = by_name[name]
        ip = c.get("ip")
        cached = state_cache.get(name, {})
        state = cached.get("state") or ""
        restarts = cached.get("restarts")
        labels = f'name="{name}",group="{group}",team="{team}",service="{service}"'
        state_lines.append(f"sabana_container_state{{{labels}}} {1 if state == 'Running' else 0}")
        if restarts is not None:
            state_lines.append(f"sabana_container_restart_count{{{labels}}} {restarts}")

        if ip and service in SERVICE_PROBES:
            port, module = SERVICE_PROBES[service]
            address = f"http://{ip}:{port}/" if module == "http_2xx" else f"{ip}:{port}"
            targets.append({
                "targets": [address],
                "labels": {
                    "group": group,
                    "team": team,
                    "service": service,
                    "name": name,
                    "probe_module": module,
                },
            })

    # vm-wiki: no vive en 'az container list' (es una VM, no un container group) -- se agrega
    # aparte con el mismo formato de target si esta desplegada.
    if wiki_ip:
        port, module = SERVICE_PROBES["wiki"]
        targets.append({
            "targets": [f"http://{wiki_ip}:{port}/"],
            "labels": {"group": "infra", "team": "", "service": "wiki", "name": "vm-wiki", "probe_module": module},
        })

    # sabana_ip_drift: compara la IP horneada con 'sed' en el dependiente contra la IP real de su
    # dependencia (ver "El huevo y la gallina" / DerivaDeIP en el plan). Solo se calcula si AMBOS
    # extremos existen -- si la dependencia fue borrada, es un problema distinto (state=0 ya lo
    # cubre) y no un drift.
    drift_pairs = [
        # (servicio dependiente, env var que lleva la IP horneada, extractor regex, servicio dependencia)
        ("webapp", "DB_HOST", r"^(.+)$", "database"),
        ("xss-bot", "WEBAPP_BASE_URL", r"^https?://([^:/]+)", "webapp"),
    ]
    for team_num in {cls[1] for cls in classified.values() if cls[1]}:
        for dep_service, env_key, pattern, target_service in drift_pairs:
            dep_name = f"team{team_num}-{dep_service}"
            target_name = f"team{team_num}-{target_service}"
            dep = by_name.get(dep_name)
            target = by_name.get(target_name)
            if not dep or not target or not target.get("ip"):
                continue
            baked = env_value(dep.get("env"), env_key)
            if not baked:
                continue
            m = re.search(pattern, baked)
            baked_ip = m.group(1) if m else None
            drift = 0 if baked_ip == target["ip"] else 1
            drift_lines.append(
                f'sabana_ip_drift{{team="{team_num}",service="{dep_service}",'
                f'depends_on="{target_service}"}} {drift}'
            )

    atomic_write(TARGETS_FILE, json.dumps(targets, indent=2) + "\n")
    atomic_write(DRIFT_PROM_FILE, "\n".join(drift_lines) + "\n")
    atomic_write(STATE_PROM_FILE, "\n".join(state_lines) + "\n")


if __name__ == "__main__":
    main()

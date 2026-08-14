#!/usr/bin/env python3
"""
gen_targets.py -- runs on vm-monitor via systemd timer (gen-targets.timer, every 60s).

See docs/plans/observability-monitoring.md "Design decision: discovery via
'az container list', not static targets" and "external probing (blackbox), not agents".

CORRECTION from the original plan: 'az container list' does NOT return populated 'instanceView' --
a limitation of the API/CLI already documented in lab-azure.sh (print_container_states(), comment
about 'az container show' per container). Confirmed again here in the first real deployment:
with 'list' the state and restartCount always come back empty. The plan assumed 'list' was enough
for all three things (IP, state, restarts) -- not true, only IP comes populated from 'list'.

That's why control plane state (secondary signal "b") is refreshed separately, with
'az container show' per container, BUT not every 60s tick -- that would violate the rate limit
for control plane that the plan warns to avoid (93 groups * 1/min = 93 calls/min).
It refreshes every STATE_REFRESH_SECONDS (5 min by default, ~93 calls/5min = well below
any ARM rate limit), parallelized with a bounded pool, and cached to disk between ticks.

Writes three files:

  - /etc/prometheus/targets/aci_targets.json
      Prometheus file_sd format. Each entry carries its real IP:port in "targets" (becomes
      __param_target via relabel_configs in prometheus.yml) and the
      group/team/service/probe_module labels that feed the "Team Wall" dashboard. Rewritten
      on EVERY tick (cheap: just one 'az container list').

  - /etc/node_exporter/textfile/sabana_drift.prom
      sabana_ip_drift (see "The alert that doesn't exist in any standard stack" in the plan).
      Rewritten every tick -- calculated from data that 'list' already brings (IP + environmentVariables
      not secure), without extra calls.

  - /etc/node_exporter/textfile/sabana_state.prom
      sabana_container_state + sabana_container_restart_count (secondary signal "b").
      Rewritten every tick from the CACHE, but the cache itself only refreshes against
      Azure every STATE_REFRESH_SECONDS.

Environment variable used: RESOURCE_GROUP (set in gen-targets.service).

Known and documented blind spot in the plan: 'xss-bot' has no probe yet -- doesn't
listen on any port until bot.js exposes /health (pending change in the
sabana-corp-network repo, out of scope for this script). Its control plane state (Running/
restartCount) IS reported -- insufficient alone (see the plan's table) but better than nothing.
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

# service (derived from container group name) -> (port, blackbox.yml module)
# Absent from this map == no blackbox probe (only control plane state). Today only applies to
# xss-bot -- see docstring.
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
    """container group name -> (group, team, service) or None if not recognized."""
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
    # mkstemp creates the file 0600 (root only) -- node-exporter/prometheus run inside their
    # containers with non-root UIDs and mount these directories read-only, so without this
    # chmod they can't read anything this script writes.
    os.chmod(tmp, 0o644)
    os.replace(tmp, path)


def load_state_cache():
    try:
        with open(STATE_CACHE_FILE) as f:
            return json.load(f)
    except (OSError, json.JSONDecodeError):
        return {}


def fetch_container_state(name):
    """One 'az container show' call -- only used from the bounded pool of refresh_state_cache."""
    result = az(
        "container", "show", "-g", RG, "-n", name,
        "--query", "{state:instanceView.state, restarts:containers[0].instanceView.restartCount}",
    )
    if result is None:
        return name, None
    return name, result


def refresh_state_cache(names):
    """Refreshes the state cache ONLY for names whose entry is older than
    STATE_REFRESH_SECONDS (or doesn't exist yet). Parallelized with a bounded pool
    to avoid turning this into 93 sequential calls -- see module docstring."""
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

    # az login --identity is idempotent (reuses cached token if still alive) -- script doesn't
    # fail if a session already exists.
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

    # Control plane state: bounded refresh (STATE_REFRESH_SECONDS), not one call per
    # name per tick -- see module docstring.
    state_cache = refresh_state_cache(list(classified.keys()))

    targets = []
    drift_lines = [
        "# HELP sabana_ip_drift 1 if the IP baked (sed) in the dependent no longer matches the "
        "real IP of its dependency -- see docs/plans/observability-monitoring.md.",
        "# TYPE sabana_ip_drift gauge",
    ]
    state_lines = [
        "# HELP sabana_container_state Control plane state of the container group (1=Running). "
        f"Refreshed every {STATE_REFRESH_SECONDS}s, not on every tick -- see module docstring.",
        "# TYPE sabana_container_state gauge",
        "# HELP sabana_container_restart_count restartCount reported by Azure for container 0.",
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

    # vm-wiki: doesn't live in 'az container list' (it's a VM, not a container group) -- added
    # separately with the same target format if deployed.
    if wiki_ip:
        port, module = SERVICE_PROBES["wiki"]
        targets.append({
            "targets": [f"http://{wiki_ip}:{port}/"],
            "labels": {"group": "infra", "team": "", "service": "wiki", "name": "vm-wiki", "probe_module": module},
        })

    # sabana_ip_drift: compares the IP baked with 'sed' in the dependent against the real IP of its
    # dependency (see "The chicken and egg" / DerivaDeIP in the plan). Calculated only if BOTH
    # ends exist -- if the dependency was deleted, it's a different problem (state=0 already covers it)
    # and not a drift.
    drift_pairs = [
        # (dependent service, env var carrying the baked IP, regex extractor, dependency service)
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

// ONLY file with knowledge of Sabana Corp: lab CIDRs, the 10.200.N.2 -> team N rule,
// and the port catalog. The rest of the package knows nothing about this particular lab.
// See docs/plans/nmap-sabana-corp.md ("How scope is determined", "Port catalog").

export const VERSION = '1.0.1'

export const TUNNEL_OVERLAY_CIDR = '10.200.0.0/16'
export const RESOLVER_IP = '10.200.0.1'
export const RESOLVER_TIMEOUT_MS = 1000

export const DMZ_CIDRS = ['10.50.0.0/24', '10.51.0.0/24']

// Superset of every possible 10.60.X.0/24 (X: 0-255). The admin peer already has
// AllowedIPs=10.0.0.0/8 on the tunnel side (access to any team is already granted), but
// WireGuard gives the client no way to enumerate which teams exist on the other end -- the
// only real signal is probing availability, which is exactly what phase A already does over
// this range.
export const TEAM_SUPERNET_CIDR = '10.60.0.0/16'

export function teamCidr(team) {
  return `10.60.${team}.0/24`
}

// Ports actually published by the lab today -- union of yamls/templates/team-*.yaml.tpl
// (database 3306, webapp 80, linux-server 22, xss-bot 80), yamls/templates/dmz-*.yaml.tpl
// (filesrv/parking 8080, and the 11 decoy-*: 21 22 25 80 110 143 445 554 873 3000 9090 9100 9418)
// and the VMs in snet-dmz-vm (wiki/ctfd: 80, 443). If a service with a new port is added to
// any of those templates, this array gets out of sync -- check here first.
export const CATALOG_PORTS = [
  21, 22, 25, 80, 110, 143, 443, 445, 554, 873, 3000, 3306, 5432, 8000, 8080, 8443, 9090, 9100, 9418
]

// Phase A (discovery): high-probability subset, probed across the entire scope.
export const PHASE_A_PORTS = [80, 22, 3306, 8080]

// Service labels derived EXCLUSIVELY from port number (generic IANA table) --
// never from host role, never from challenge. See "The rule governing what is shown" in the plan.
const SERVICE_NAMES = {
  21: 'ftp',
  22: 'ssh',
  25: 'smtp',
  80: 'http',
  110: 'pop3',
  143: 'imap',
  443: 'https',
  445: 'microsoft-ds',
  554: 'rtsp',
  873: 'rsync',
  3000: 'ppp',
  3306: 'mysql',
  5432: 'postgresql',
  8000: 'irdmi',
  8080: 'http-alt',
  8443: 'https-alt',
  9090: 'zeus-admin',
  9100: 'jetdirect',
  9418: 'git'
}

export function serviceForPort(port) {
  return SERVICE_NAMES[port] ?? 'unknown'
}

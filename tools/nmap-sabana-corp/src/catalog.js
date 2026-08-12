// UNICO archivo con conocimiento de Sabana Corp: CIDRs del lab, la regla 10.200.N.2 -> equipo N,
// y el catalogo de puertos. El resto del paquete no sabe nada de este lab en particular.
// Ver docs/plans/nmap-sabana-corp.md ("Cómo se determina el alcance", "Catálogo de puertos").

export const VERSION = '0.1.0-draft'

export const TUNNEL_OVERLAY_CIDR = '10.200.0.0/16'
export const RESOLVER_IP = '10.200.0.1'
export const RESOLVER_TIMEOUT_MS = 1000

export const DMZ_CIDRS = ['10.50.0.0/24', '10.51.0.0/24']

export function teamCidr(team) {
  return `10.60.${team}.0/24`
}

// Puertos publicados de verdad por el lab hoy -- union de yamls/templates/team-*.yaml.tpl
// (database 3306, webapp 80, linux-server 22, xss-bot 80), yamls/templates/dmz-*.yaml.tpl
// (filesrv/parking 8080, y los 11 decoy-*: 21 22 25 80 110 143 445 554 873 3000 9090 9100 9418)
// y las VMs de snet-dmz-vm (wiki/ctfd: 80, 443). Si se agrega un servicio con un puerto nuevo a
// cualquiera de esas plantillas, este array se desincroniza -- revisar aqui primero.
export const CATALOG_PORTS = [
  21, 22, 25, 80, 110, 143, 443, 445, 554, 873, 3000, 3306, 5432, 8000, 8080, 8443, 9090, 9100, 9418
]

// Fase A (descubrimiento): subconjunto de alta probabilidad, sondeado sobre TODO el alcance.
export const PHASE_A_PORTS = [80, 22, 3306, 8080]

// Etiquetas de servicio derivadas EXCLUSIVAMENTE del numero de puerto (tabla IANA generica) --
// nunca del rol del host, nunca del reto. Ver "La regla que gobierna que se muestra" del plan.
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

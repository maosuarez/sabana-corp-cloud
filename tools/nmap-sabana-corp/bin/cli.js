#!/usr/bin/env node
// Parseo de flags, orquestacion (alcance -> escaneo -> nombres -> render), codigos de salida.
// 0 = corrida normal (incluye "0 hosts vivos", eso no es un error). 2 = error accionable del
// usuario (alcance no derivable, flag invalida). 1 = error inesperado.

import { CATALOG_PORTS, RESOLVER_IP, VERSION, serviceForPort } from '../src/catalog.js'
import { resolveNames } from '../src/names.js'
import { renderJson, renderText } from '../src/render.js'
import { DEFAULT_CONCURRENCY, scan } from '../src/scan.js'
import { ScopeError, resolveScope } from '../src/scope.js'

class CliError extends Error {}

const HELP = `nmap-sabana-corp v${VERSION} -- descubrimiento de red para el CTF de Sabana Corp

Uso:
  nmap-sabana-corp [--scan] [opciones]

Opciones:
  --cidr <a,b,c>      alcance explicito (staff / casos raros). Nunca automatico.
  --conf <ruta>       deriva el alcance de AllowedIPs en un .conf de WireGuard (autoritativo).
  --ports <a,b,c>     puertos extra a sumar al catalogo del lab.
  --concurrency <n>   sockets simultaneos (por defecto ${DEFAULT_CONCURRENCY}).
  --json              salida en JSON en vez de tabla de texto.
  --scan              no-op explicito: escanear es lo unico que hace este comando.
  --version           imprime la version y sale.
  --help              esta ayuda.

Sin --cidr ni --conf, el alcance se deriva de la interfaz de tunel WireGuard activa (busca una
direccion dentro de 10.200.0.0/16). No banners, no version de servicio, no deteccion de SO -- ver
README.md para el detalle completo y la lista de lo que esta herramienta nunca muestra.
`

function parseArgs(argv) {
  const args = { json: false }
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i]
    switch (arg) {
      case '--cidr':
        args.cidr = argv[++i]
        break
      case '--conf':
        args.conf = argv[++i]
        break
      case '--ports':
        args.ports = argv[++i]
        break
      case '--concurrency':
        args.concurrency = Number(argv[++i])
        break
      case '--json':
        args.json = true
        break
      case '--scan':
        break
      case '--version':
        args.version = true
        break
      case '--help':
      case '-h':
        args.help = true
        break
      default:
        throw new CliError(`opcion no reconocida: ${arg} (usa --help)`)
    }
  }
  return args
}

async function main() {
  const args = parseArgs(process.argv.slice(2))

  if (args.help) {
    process.stdout.write(HELP)
    return 0
  }
  if (args.version) {
    process.stdout.write(`${VERSION}\n`)
    return 0
  }

  const scope = resolveScope({ cidrArg: args.cidr, confPath: args.conf })

  const extraPorts = args.ports
    ? args.ports
        .split(',')
        .map((p) => Number(p.trim()))
        .filter((p) => Number.isInteger(p) && p > 0)
    : []
  const ports = [...new Set([...CATALOG_PORTS, ...extraPorts])].sort((a, b) => a - b)

  const scanOptions = { cidrs: scope.cidrs, ports }
  if (args.concurrency) scanOptions.concurrency = args.concurrency

  const result = await scan(scanOptions)
  const { fqdnByIp, resolverUp } = await resolveNames(result.hosts.map((h) => h.ip))

  const hosts = result.hosts.map((h) => ({
    ip: h.ip,
    cidr: h.cidr,
    fqdn: fqdnByIp.get(h.ip) ?? null,
    ports: h.ports.map((port) => ({ port, proto: 'tcp', service: serviceForPort(port) }))
  }))

  const data = {
    version: VERSION,
    scope,
    resolver: { ip: RESOLVER_IP, up: resolverUp },
    hosts,
    stats: {
      addressesScanned: result.addressesScanned,
      portsOpen: result.portsOpen,
      elapsedMs: result.elapsedMs
    }
  }

  process.stdout.write((args.json ? renderJson(data) : renderText(data)) + '\n')
  return 0
}

main()
  .then((code) => process.exit(code ?? 0))
  .catch((err) => {
    if (err instanceof ScopeError || err instanceof CliError) {
      process.stderr.write(`[ERROR] ${err.message}\n`)
      process.exit(2)
    }
    process.stderr.write(`[ERROR] ${err.stack ?? err.message}\n`)
    process.exit(1)
  })

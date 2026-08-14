#!/usr/bin/env node
// Flag parsing, orchestration (scope -> scan -> names -> render), exit codes.
// 0 = normal run (includes "0 hosts alive", that's not an error). 2 = user-actionable error
// (scope not derivable, invalid flag). 1 = unexpected error.

import { CATALOG_PORTS, RESOLVER_IP, VERSION, serviceForPort } from '../src/catalog.js'
import { resolveNames } from '../src/names.js'
import { renderJson, renderText } from '../src/render.js'
import { DEFAULT_CONCURRENCY, scan } from '../src/scan.js'
import { ScopeError, resolveScope } from '../src/scope.js'

class CliError extends Error {}

const HELP = `nmap-sabana-corp v${VERSION} -- network discovery for the Sabana Corp CTF

Usage:
  nmap-sabana-corp [--scan] [options]

Options:
  --cidr <a,b,c>      explicit scope (staff / edge cases). Never automatic.
  --conf <path>       derives scope from AllowedIPs in a WireGuard .conf (authoritative).
  --ports <a,b,c>     extra ports to add to the lab catalog.
  --concurrency <n>   simultaneous sockets (default ${DEFAULT_CONCURRENCY}).
  --json              output in JSON instead of text table.
  --scan              explicit no-op: scanning is the only thing this command does.
  --version           print the version and exit.
  --help              this help.

Without --cidr or --conf, scope is derived from the active WireGuard tunnel interface (looks for
an address within 10.200.0.0/16). No banners, no service version, no OS detection -- see
README.md for full details and the list of what this tool never shows.
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
        throw new CliError(`unrecognized option: ${arg} (use --help)`)
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

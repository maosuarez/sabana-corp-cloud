// "Output format": text table or --json, same fields in both. Never prints anything
// that the "What is explicitly NOT shown" table forbids -- see docs/plans/nmap-sabana-corp.md.
// Rule of this layer: service label comes only from port number (catalog.js),
// never from host role.

function pad(text, width) {
  return text.length >= width ? text : text + ' '.repeat(width - text.length)
}

function formatPorts(ports) {
  return ports.map((p) => `${p.port}/tcp ${p.service}`).join(', ')
}

function scopeHeaderLines(data) {
  const lines = []
  lines.push(`nmap-sabana-corp v${data.version} -- TCP connect scan of accessible environment (no privileges)`)
  lines.push(`scope    : ${data.scope.cidrs.join(', ')}   (source: ${data.scope.origin})`)
  if (data.scope.warning) lines.push(data.scope.warning)
  lines.push(
    data.resolver.up
      ? `names    : ${data.resolver.ip} (lab resolver, up)`
      : `names    : ${data.resolver.ip} (lab resolver, no response -- showing IPs only)`
  )
  return lines
}

export function renderText(data) {
  const lines = [...scopeHeaderLines(data), '']

  const hostsByCidr = new Map()
  for (const cidr of data.scope.cidrs) hostsByCidr.set(cidr, [])
  for (const host of data.hosts) {
    if (!hostsByCidr.has(host.cidr)) hostsByCidr.set(host.cidr, [])
    hostsByCidr.get(host.cidr).push(host)
  }

  const ipWidth = Math.max(2, ...data.hosts.map((h) => h.ip.length)) + 3
  const fqdnWidth = Math.max(4, ...data.hosts.map((h) => (h.fqdn ?? '-').length)) + 3

  let headerPrinted = false
  for (const [cidr, hosts] of hostsByCidr) {
    if (hosts.length === 0) continue
    lines.push(`-- ${cidr} ${'-'.repeat(Math.max(0, 76 - cidr.length))}`)
    if (!headerPrinted) {
      lines.push(`${pad('IP', ipWidth)}${pad('FQDN', fqdnWidth)}OPEN PORTS`)
      headerPrinted = true
    }
    for (const host of [...hosts].sort((a, b) => (a.ip > b.ip ? 1 : -1))) {
      lines.push(`${pad(host.ip, ipWidth)}${pad(host.fqdn ?? '-', fqdnWidth)}${formatPorts(host.ports)}`)
    }
    lines.push('')
  }

  const elapsedSeconds = (data.stats.elapsedMs / 1000).toFixed(1)
  lines.push(
    `${data.hosts.length} hosts alive - ${data.stats.portsOpen} open ports - ` +
      `${data.stats.addressesScanned} addresses probed in ${elapsedSeconds} s`
  )

  if (data.hosts.length === 0) {
    lines.push('if you expected to see something here: first verify your tunnel (--conf confirms the exact AllowedIPs), then tell staff.')
  } else if (data.resolver.up) {
    const withoutFqdn = data.hosts.filter((h) => !h.fqdn).length
    if (withoutFqdn > 0) {
      lines.push(`${withoutFqdn} hosts without FQDN (no DNS record; this is not a failure -- see README)`)
    }
  }

  return lines.join('\n')
}

export function renderJson(data) {
  return JSON.stringify(
    {
      version: data.version,
      scope: data.scope,
      resolver: data.resolver,
      hosts: data.hosts.map((h) => ({ ip: h.ip, cidr: h.cidr, fqdn: h.fqdn, ports: h.ports })),
      stats: {
        hostsAlive: data.hosts.length,
        portsOpen: data.stats.portsOpen,
        addressesScanned: data.stats.addressesScanned,
        elapsedSeconds: Number((data.stats.elapsedMs / 1000).toFixed(1))
      }
    },
    null,
    2
  )
}

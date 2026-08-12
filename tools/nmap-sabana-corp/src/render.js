// "Formato del output": tabla de texto o --json, mismos campos en los dos. Nunca imprime nada
// que la tabla "Lo que explícitamente NO se muestra" prohíba -- ver docs/plans/nmap-sabana-corp.md.
// Regla de esta capa: la etiqueta de servicio sale solo del numero de puerto (catalog.js),
// jamas del rol del host.

function pad(text, width) {
  return text.length >= width ? text : text + ' '.repeat(width - text.length)
}

function formatPorts(ports) {
  return ports.map((p) => `${p.port}/tcp ${p.service}`).join(', ')
}

function scopeHeaderLines(data) {
  const lines = []
  lines.push(`nmap-sabana-corp v${data.version} -- barrido TCP connect del entorno accesible (sin privilegios)`)
  lines.push(`alcance : ${data.scope.cidrs.join(', ')}   (origen: ${data.scope.origin})`)
  if (data.scope.warning) lines.push(data.scope.warning)
  lines.push(
    data.resolver.up
      ? `nombres : ${data.resolver.ip} (resolutor del lab, activo)`
      : `nombres : ${data.resolver.ip} (resolutor del lab, sin respuesta -- mostrando solo IPs)`
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
      lines.push(`${pad('IP', ipWidth)}${pad('FQDN', fqdnWidth)}PUERTOS ABIERTOS`)
      headerPrinted = true
    }
    for (const host of [...hosts].sort((a, b) => (a.ip > b.ip ? 1 : -1))) {
      lines.push(`${pad(host.ip, ipWidth)}${pad(host.fqdn ?? '-', fqdnWidth)}${formatPorts(host.ports)}`)
    }
    lines.push('')
  }

  const elapsedSeconds = (data.stats.elapsedMs / 1000).toFixed(1)
  lines.push(
    `${data.hosts.length} hosts vivos - ${data.stats.portsOpen} puertos abiertos - ` +
      `${data.stats.addressesScanned} direcciones sondeadas en ${elapsedSeconds} s`
  )

  if (data.hosts.length === 0) {
    lines.push('si esperabas ver algo aca: primero verifica tu tunel (--conf te confirma el AllowedIPs exacto), luego avisa al staff.')
  } else if (data.resolver.up) {
    const withoutFqdn = data.hosts.filter((h) => !h.fqdn).length
    if (withoutFqdn > 0) {
      lines.push(`${withoutFqdn} hosts sin FQDN (sin registro DNS; no es un fallo -- ver README)`)
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

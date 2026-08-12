// "Cómo se escanea": TCP connect scan real (net.Socket, sin sockets raw, sin root), dos fases.
// Fase A descubre hosts vivos con un puñado de puertos y cancela el resto en cuanto uno responde.
// Fase B mide el catalogo completo, solo contra los hosts vivos. Ver docs/plans/nmap-sabana-corp.md.

import net from 'node:net'
import { CATALOG_PORTS, PHASE_A_PORTS } from './catalog.js'
import { hostsInCidr } from './scope.js'

export const DEFAULT_CONCURRENCY = 128
// Empiricamente, ~5-8s de barrido total para 3 x /24 vienen de un timeout corto por intento --
// la mayoria de direcciones del rango estan vacias y el costo lo domina ese timeout, no la red.
export const DEFAULT_TIMEOUT_MS = 300

function connectPort(ip, port, timeoutMs) {
  return new Promise((resolve) => {
    const socket = new net.Socket()
    let settled = false
    const finish = (status) => {
      if (settled) return
      settled = true
      socket.destroy()
      resolve(status)
    }
    socket.setTimeout(timeoutMs)
    socket.once('connect', () => finish('open'))
    socket.once('timeout', () => finish('timeout'))
    socket.once('error', (err) => finish(err.code === 'ECONNREFUSED' ? 'closed' : 'timeout'))
    socket.connect(port, ip)
  })
}

// Ejecuta `worker` sobre `items` con a lo sumo `concurrency` tareas en vuelo a la vez.
export async function runPool(items, worker, concurrency) {
  const results = new Array(items.length)
  let cursor = 0
  async function lane() {
    while (cursor < items.length) {
      const current = cursor++
      results[current] = await worker(items[current], current)
    }
  }
  const laneCount = Math.min(concurrency, items.length)
  await Promise.all(Array.from({ length: laneCount }, lane))
  return results
}

// "Un host esta vivo si al menos un puerto del catalogo responde (aceptado o rechazado
// explicitamente)". Recorre los puertos de Fase A en orden y se detiene en el primero que no de
// timeout -- esa es la cancelacion por host.
async function probeHostAlive(ip, ports, timeoutMs) {
  for (const port of ports) {
    const status = await connectPort(ip, port, timeoutMs)
    if (status !== 'timeout') return true
  }
  return false
}

export async function scan({
  cidrs,
  ports = CATALOG_PORTS,
  phaseAPorts = PHASE_A_PORTS,
  concurrency = DEFAULT_CONCURRENCY,
  timeoutMs = DEFAULT_TIMEOUT_MS,
  // Nombre distinto al de la funcion importada (`hostsInCidr`) a proposito: un parametro con el
  // mismo nombre no puede referenciar el binding externo en su propio valor por defecto.
  hostsInCidr: hostsInCidrFn = hostsInCidr
}) {
  const start = Date.now()

  const hostToCidr = new Map()
  for (const cidr of cidrs) {
    for (const ip of hostsInCidrFn(cidr)) hostToCidr.set(ip, cidr)
  }
  const allHosts = [...hostToCidr.keys()]

  const aliveFlags = await runPool(allHosts, (ip) => probeHostAlive(ip, phaseAPorts, timeoutMs), concurrency)
  const liveHosts = allHosts.filter((_ip, i) => aliveFlags[i])

  const portTasks = []
  for (const ip of liveHosts) {
    for (const port of ports) portTasks.push({ ip, port })
  }
  const portResults = await runPool(
    portTasks,
    async ({ ip, port }) => ({ ip, port, status: await connectPort(ip, port, timeoutMs) }),
    concurrency
  )

  const openPortsByHost = new Map()
  for (const { ip, port, status } of portResults) {
    if (status !== 'open') continue
    if (!openPortsByHost.has(ip)) openPortsByHost.set(ip, [])
    openPortsByHost.get(ip).push(port)
  }

  const hosts = liveHosts.map((ip) => ({
    ip,
    cidr: hostToCidr.get(ip),
    ports: (openPortsByHost.get(ip) ?? []).sort((a, b) => a - b)
  }))

  return {
    hosts,
    addressesScanned: allHosts.length,
    portsOpen: hosts.reduce((sum, h) => sum + h.ports.length, 0),
    elapsedMs: Date.now() - start
  }
}

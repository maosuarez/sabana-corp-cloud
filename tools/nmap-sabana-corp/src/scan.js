// "How scanning works": real TCP connect scan (net.Socket, no raw sockets, no root), two phases.
// Phase A discovers live hosts with a handful of ports and cancels the rest as soon as one responds.
// Phase B measures the complete catalog, only against live hosts. See docs/plans/nmap-sabana-corp.md.

import net from 'node:net'
import { CATALOG_PORTS, PHASE_A_PORTS } from './catalog.js'
import { hostsInCidr } from './scope.js'

export const DEFAULT_CONCURRENCY = 128
// Empirically, ~5-8s of total scan for 3 x /24 comes from a short timeout per attempt --
// most addresses in the range are empty and that timeout dominates the cost, not the network.
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

// Runs `worker` on `items` with at most `concurrency` tasks in flight at once.
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

// "A host is alive if at least one port from the catalog responds (accepted or explicitly
// rejected)". Iterates through Phase A ports in order and stops at the first one that doesn't
// timeout -- that's the per-host cancellation.
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
  // Different name from the imported function (`hostsInCidr`) on purpose: a parameter with the
  // same name cannot reference the external binding in its own default value.
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

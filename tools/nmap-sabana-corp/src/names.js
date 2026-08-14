// "How names are resolved": PTR against the lab's resolver (10.200.0.1), never the OS's --
// new dns.Resolver() + setServers() talks c-ares directly to that IP and ignores the
// system's DNS configuration. Degrades to "no names" if it doesn't respond in 1s; DNS decorates,
// never mandates. See docs/plans/nmap-sabana-corp.md.

import dns from 'node:dns'
import { RESOLVER_IP, RESOLVER_TIMEOUT_MS } from './catalog.js'

// Individual promise is not canceled on timeout -- that would require resolver.cancel(),
// which cancels ALL in-flight queries from the resolver, not just this one, and there may be
// others legitimately in flight here (the other IPs from resolveNames). It's left to
// resolve/reject in the background and the result is discarded; resolveNames() handles cleaning
// up the entire resolver once, when no more queries of its own are left to wait for.
function withTimeout(promise, ms) {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error('timeout')), ms)
    promise.then(
      (value) => {
        clearTimeout(timer)
        resolve(value)
      },
      (err) => {
        clearTimeout(timer)
        reject(err)
      }
    )
  })
}

async function isResolverUp(resolver, resolverIp) {
  try {
    await withTimeout(
      // The resolver's own IP is queried, never 127.0.0.1: Node/c-ares resolves
      // loopback locally without touching the network, which would give a false "up" even if
      // the configured resolver doesn't respond.
      resolver.reverse(resolverIp).catch((err) => {
        // NXDOMAIN/no data is a real resolver response, not a crash.
        if (err.code === 'ENOTFOUND' || err.code === 'ENODATA') return []
        throw err
      }),
      RESOLVER_TIMEOUT_MS
    )
    return true
  } catch {
    return false
  }
}

export async function resolveNames(ips, { resolverIp = RESOLVER_IP } = {}) {
  const resolver = new dns.promises.Resolver()
  resolver.setServers([resolverIp])

  if (!(await isResolverUp(resolver, resolverIp))) {
    // Nothing else is pending on this resolver (the check above already covers it). Cancelling
    // here prevents the losing query in the timeout race from keeping the event loop alive.
    resolver.cancel()
    return { fqdnByIp: new Map(), resolverUp: false }
  }

  const entries = await Promise.all(
    ips.map(async (ip) => {
      try {
        const names = await withTimeout(resolver.reverse(ip), RESOLVER_TIMEOUT_MS)
        return [ip, names[0] ?? null]
      } catch {
        return [ip, null]
      }
    })
  )
  // Same: at this point, no queries of its own are left to wait for, even if some lost
  // their timeout race and are still hung on the resolver.
  resolver.cancel()

  return { fqdnByIp: new Map(entries), resolverUp: true }
}

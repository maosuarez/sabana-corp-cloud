// "Cómo se resuelven los nombres": PTR contra el resolutor del lab (10.200.0.1), nunca el del
// SO -- new dns.Resolver() + setServers() habla c-ares directo a esa IP e ignora la
// configuracion DNS del sistema. Degrada a "sin nombres" si no responde en 1s; el DNS decora,
// nunca manda. Ver docs/plans/nmap-sabana-corp.md.

import dns from 'node:dns'
import { RESOLVER_IP, RESOLVER_TIMEOUT_MS } from './catalog.js'

// No se cancela la promesa individual al vencer su timeout -- eso exigiria resolver.cancel(),
// que cancela TODAS las consultas en vuelo del resolver, no solo esta, y aqui puede haber otras
// legitimamente en curso (las demas IPs de resolveNames). Se deja que resuelva/rechace en
// segundo plano y se descarta el resultado; resolveNames() se encarga de limpiar el resolver
// entero una sola vez, cuando ya no le queda ninguna consulta propia por esperar.
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
      // Se consulta la IP del propio resolutor, nunca 127.0.0.1: Node/c-ares resuelve el
      // loopback localmente sin tocar la red, lo que daria un falso "activo" aunque el resolutor
      // configurado no responda.
      resolver.reverse(resolverIp).catch((err) => {
        // NXDOMAIN/sin datos es una respuesta real del resolutor, no una caida.
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
    // Nada mas queda pendiente en este resolver (el propio chequeo de arriba). Cancelar aqui
    // evita que la consulta perdedora de la carrera del timeout mantenga vivo el event loop.
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
  // Idem: para aqui ya no queda ninguna consulta propia por esperar, aunque alguna haya perdido
  // su carrera de timeout y siga colgada en el resolver.
  resolver.cancel()

  return { fqdnByIp: new Map(entries), resolverUp: true }
}

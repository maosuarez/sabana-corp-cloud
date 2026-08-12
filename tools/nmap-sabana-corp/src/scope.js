// S1/S2/S3 de "Cómo se determina el alcance": --cidr explicito, --conf autoritativo, o
// derivacion desde os.networkInterfaces() buscando la interfaz del tunel WireGuard. La primera
// fuente disponible gana; ver docs/plans/nmap-sabana-corp.md.

import fs from 'node:fs'
import os from 'node:os'
import { DMZ_CIDRS, TUNNEL_OVERLAY_CIDR, teamCidr } from './catalog.js'

export class ScopeError extends Error {}

const ALLOWED_IPS_LINE = /^\s*AllowedIPs\s*=\s*(.+?)\s*$/im

export function parseAllowedIps(confText) {
  const match = ALLOWED_IPS_LINE.exec(confText)
  if (!match) {
    throw new ScopeError('el .conf no tiene una linea AllowedIPs -- ¿es un .conf de WireGuard valido?')
  }
  return match[1]
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
}

function ipToInt(ip) {
  const parts = ip.split('.').map(Number)
  if (parts.length !== 4 || parts.some((p) => !Number.isInteger(p) || p < 0 || p > 255)) {
    throw new ScopeError(`direccion IPv4 invalida: ${ip}`)
  }
  return ((parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3]) >>> 0
}

function intToIp(n) {
  return [24, 16, 8, 0].map((shift) => (n >>> shift) & 0xff).join('.')
}

function parseCidr(cidr) {
  const [ip, prefixStr] = cidr.split('/')
  const prefix = prefixStr === undefined ? 32 : Number(prefixStr)
  if (!Number.isInteger(prefix) || prefix < 0 || prefix > 32) {
    throw new ScopeError(`CIDR invalido: ${cidr}`)
  }
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0
  // `>>> 0` es obligatorio en las dos lineas: `&`/`|` devuelven un int32 con signo, y comparar
  // ese resultado con signo contra un limite sin signo (IPs con el primer octeto >= 128) hace
  // que el rango parezca abarcar casi todo el espacio de direcciones.
  const networkInt = (ipToInt(ip) & mask) >>> 0
  const broadcastInt = (networkInt | (~mask >>> 0)) >>> 0
  return { networkInt, broadcastInt, prefix }
}

export function ipInCidr(ip, cidr) {
  const { networkInt, broadcastInt } = parseCidr(cidr)
  const target = ipToInt(ip)
  return target >= networkInt && target <= broadcastInt
}

// /31 y /32 no tienen direccion de red/broadcast que excluir (RFC 3021 para /31; /32 es un solo
// host) -- el resto excluye las dos puntas, como hace cualquier host util real.
export function* hostsInCidr(cidr) {
  const { networkInt, broadcastInt, prefix } = parseCidr(cidr)
  if (prefix >= 31) {
    for (let n = networkInt; n <= broadcastInt; n++) yield intToIp(n)
    return
  }
  for (let n = networkInt + 1; n < broadcastInt; n++) yield intToIp(n)
}

export function cidrHostCount(cidr) {
  const { networkInt, broadcastInt, prefix } = parseCidr(cidr)
  return prefix >= 31 ? broadcastInt - networkInt + 1 : Math.max(0, broadcastInt - networkInt - 1)
}

const TEAM_TUNNEL_ADDRESS = /^10\.200\.(\d{1,3})\.2$/

// Devuelve: numero de equipo, `null` si es el peer admin (10.200.0.2, sin equipo derivable), o
// `undefined` si la direccion cae en el overlay pero no encaja en ninguno de los dos patrones
// documentados en lab-azure.sh (create_wg_peer / create_wg_team_peer).
export function teamFromTunnelAddress(address) {
  const match = TEAM_TUNNEL_ADDRESS.exec(address)
  if (!match) return undefined
  const team = Number(match[1])
  return team === 0 ? null : team
}

export function deriveScopeFromInterfaces(interfaces) {
  const candidates = []
  for (const [ifaceName, addrs] of Object.entries(interfaces ?? {})) {
    for (const addr of addrs ?? []) {
      if (addr.family !== 'IPv4' && addr.family !== 4) continue
      if (ipInCidr(addr.address, TUNNEL_OVERLAY_CIDR)) {
        candidates.push({ iface: ifaceName, address: addr.address })
      }
    }
  }

  if (candidates.length === 0) {
    throw new ScopeError(
      `no veo un tunel de Sabana Corp activo (ninguna interfaz dentro de ${TUNNEL_OVERLAY_CIDR}); ` +
        'levanta la VPN o pasa --conf/--cidr'
    )
  }

  if (candidates.length > 1) {
    const list = candidates.map((c) => `${c.iface} (${c.address})`).join(', ')
    throw new ScopeError(
      `varias interfaces dentro de ${TUNNEL_OVERLAY_CIDR}: ${list} -- pasa --conf/--cidr para desambiguar`
    )
  }

  const { address } = candidates[0]
  const team = teamFromTunnelAddress(address)

  if (team === undefined) {
    throw new ScopeError(
      `direccion de tunel no reconocida (${address}); no encaja con equipo ni con el peer admin -- pasa --conf/--cidr`
    )
  }

  if (team === null) {
    return {
      cidrs: [...DMZ_CIDRS],
      origin: `interfaz de tunel ${address} (peer admin)`,
      warning: 'peer admin detectado; usa --cidr para mas alcance'
    }
  }

  return {
    cidrs: [teamCidr(team), ...DMZ_CIDRS],
    origin: `interfaz de tunel ${address}`,
    warning: null
  }
}

function defaultReadFile(path) {
  return fs.readFileSync(path, 'utf8')
}

// Orquesta S1 (--cidr) > S2 (--conf) > S3 (derivacion automatica). La primera fuente presente
// gana; nunca se combinan.
export function resolveScope({ cidrArg, confPath, interfaces, readFile = defaultReadFile } = {}) {
  if (cidrArg) {
    const cidrs = cidrArg
      .split(',')
      .map((entry) => entry.trim())
      .filter(Boolean)
    if (cidrs.length === 0) throw new ScopeError('--cidr no trae ningun CIDR valido')
    return { cidrs, origin: '--cidr', warning: null }
  }

  if (confPath) {
    const cidrs = parseAllowedIps(readFile(confPath))
    return { cidrs, origin: `--conf ${confPath}`, warning: null }
  }

  return deriveScopeFromInterfaces(interfaces ?? os.networkInterfaces())
}

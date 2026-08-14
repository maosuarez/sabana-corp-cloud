// S1/S2/S3 from "How scope is determined": explicit --cidr, authoritative --conf, or
// derivation from os.networkInterfaces() looking for the WireGuard tunnel interface. The first
// available source wins; see docs/plans/nmap-sabana-corp.md.

import fs from 'node:fs'
import os from 'node:os'
import { DMZ_CIDRS, TEAM_SUPERNET_CIDR, TUNNEL_OVERLAY_CIDR, teamCidr } from './catalog.js'

export class ScopeError extends Error {}

const ALLOWED_IPS_LINE = /^\s*AllowedIPs\s*=\s*(.+?)\s*$/im

export function parseAllowedIps(confText) {
  const match = ALLOWED_IPS_LINE.exec(confText)
  if (!match) {
    throw new ScopeError('.conf does not have an AllowedIPs line -- is it a valid WireGuard .conf?')
  }
  return match[1]
    .split(',')
    .map((entry) => entry.trim())
    .filter(Boolean)
}

function ipToInt(ip) {
  const parts = ip.split('.').map(Number)
  if (parts.length !== 4 || parts.some((p) => !Number.isInteger(p) || p < 0 || p > 255)) {
    throw new ScopeError(`invalid IPv4 address: ${ip}`)
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
    throw new ScopeError(`invalid CIDR: ${cidr}`)
  }
  const mask = prefix === 0 ? 0 : (0xffffffff << (32 - prefix)) >>> 0
  // `>>> 0` is mandatory in both lines: `&`/`|` return a signed int32, and comparing
  // that signed result against an unsigned limit (IPs with first octet >= 128) makes
  // the range appear to span almost the entire address space.
  const networkInt = (ipToInt(ip) & mask) >>> 0
  const broadcastInt = (networkInt | (~mask >>> 0)) >>> 0
  return { networkInt, broadcastInt, prefix }
}

export function ipInCidr(ip, cidr) {
  const { networkInt, broadcastInt } = parseCidr(cidr)
  const target = ipToInt(ip)
  return target >= networkInt && target <= broadcastInt
}

// /31 and /32 have no network/broadcast address to exclude (RFC 3021 for /31; /32 is a single
// host) -- the rest excludes both endpoints, like any real usable host does.
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

// Returns: team number, `null` if it's the admin peer (10.200.0.2, no team derivable), or
// `undefined` if the address falls in the overlay but doesn't match either of the two patterns
// documented in lab-azure.sh (create_wg_peer / create_wg_team_peer).
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
      `I don't see an active Sabana Corp tunnel (no interface within ${TUNNEL_OVERLAY_CIDR}); ` +
        'bring up the VPN or pass --conf/--cidr'
    )
  }

  if (candidates.length > 1) {
    const list = candidates.map((c) => `${c.iface} (${c.address})`).join(', ')
    throw new ScopeError(
      `several interfaces within ${TUNNEL_OVERLAY_CIDR}: ${list} -- pass --conf/--cidr to disambiguate`
    )
  }

  const { address } = candidates[0]
  const team = teamFromTunnelAddress(address)

  if (team === undefined) {
    throw new ScopeError(
      `unrecognized tunnel address (${address}); matches neither team nor admin peer -- pass --conf/--cidr`
    )
  }

  if (team === null) {
    return {
      cidrs: [TEAM_SUPERNET_CIDR, ...DMZ_CIDRS],
      origin: `tunnel interface ${address} (admin peer)`,
      warning: `admin peer detected; sweeping ${TEAM_SUPERNET_CIDR} for live teams, this takes longer than a single team's scan`
    }
  }

  return {
    cidrs: [teamCidr(team), ...DMZ_CIDRS],
    origin: `tunnel interface ${address}`,
    warning: null
  }
}

function defaultReadFile(path) {
  return fs.readFileSync(path, 'utf8')
}

// Orchestrates S1 (--cidr) > S2 (--conf) > S3 (automatic derivation). The first present source
// wins; they are never combined.
export function resolveScope({ cidrArg, confPath, interfaces, readFile = defaultReadFile } = {}) {
  if (cidrArg) {
    const cidrs = cidrArg
      .split(',')
      .map((entry) => entry.trim())
      .filter(Boolean)
    if (cidrs.length === 0) throw new ScopeError('--cidr yields no valid CIDR')
    return { cidrs, origin: '--cidr', warning: null }
  }

  if (confPath) {
    const cidrs = parseAllowedIps(readFile(confPath))
    return { cidrs, origin: `--conf ${confPath}`, warning: null }
  }

  return deriveScopeFromInterfaces(interfaces ?? os.networkInterfaces())
}

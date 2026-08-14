import assert from 'node:assert/strict'
import { test } from 'node:test'
import {
  ScopeError,
  cidrHostCount,
  deriveScopeFromInterfaces,
  hostsInCidr,
  ipInCidr,
  parseAllowedIps,
  resolveScope,
  teamFromTunnelAddress
} from '../src/scope.js'

test('parseAllowedIps: separated by comma and space', () => {
  const conf = `[Interface]\nAddress = 10.200.3.2/32\n\n[Peer]\nAllowedIPs = 10.60.3.0/24, 10.50.0.0/24, 10.51.0.0/24\n`
  assert.deepEqual(parseAllowedIps(conf), ['10.60.3.0/24', '10.50.0.0/24', '10.51.0.0/24'])
})

test('parseAllowedIps: no spaces and extra spaces around =', () => {
  const conf = 'AllowedIPs=10.60.7.0/24,10.50.0.0/24,10.51.0.0/24'
  assert.deepEqual(parseAllowedIps(conf), ['10.60.7.0/24', '10.50.0.0/24', '10.51.0.0/24'])

  const spaced = 'AllowedIPs   =   10.60.7.0/24 , 10.50.0.0/24 ,10.51.0.0/24'
  assert.deepEqual(parseAllowedIps(spaced), ['10.60.7.0/24', '10.50.0.0/24', '10.51.0.0/24'])
})

test('parseAllowedIps: no AllowedIPs line -> ScopeError', () => {
  assert.throws(() => parseAllowedIps('[Interface]\nAddress = 10.200.3.2/32\n'), ScopeError)
})

test('teamFromTunnelAddress: 10.200.N.2 -> team N', () => {
  assert.equal(teamFromTunnelAddress('10.200.7.2'), 7)
  assert.equal(teamFromTunnelAddress('10.200.42.2'), 42)
})

test('teamFromTunnelAddress: 10.200.0.2 -> admin (null)', () => {
  assert.equal(teamFromTunnelAddress('10.200.0.2'), null)
})

test('teamFromTunnelAddress: address that does not match -> undefined', () => {
  assert.equal(teamFromTunnelAddress('10.200.7.5'), undefined)
  assert.equal(teamFromTunnelAddress('10.60.7.2'), undefined)
})

test('deriveScopeFromInterfaces: interface 10.200.7.2 -> team7 + both DMZ', () => {
  const interfaces = {
    wg0: [{ address: '10.200.7.2', family: 'IPv4', internal: false }],
    lo: [{ address: '127.0.0.1', family: 'IPv4', internal: true }]
  }
  const scope = deriveScopeFromInterfaces(interfaces)
  assert.deepEqual(scope.cidrs, ['10.60.7.0/24', '10.50.0.0/24', '10.51.0.0/24'])
  assert.equal(scope.warning, null)
  assert.match(scope.origin, /10\.200\.7\.2/)
})

test('deriveScopeFromInterfaces: admin peer (10.200.0.2) -> team supernet + DMZ + warning', () => {
  const interfaces = { utun4: [{ address: '10.200.0.2', family: 'IPv4', internal: false }] }
  const scope = deriveScopeFromInterfaces(interfaces)
  assert.deepEqual(scope.cidrs, ['10.60.0.0/16', '10.50.0.0/24', '10.51.0.0/24'])
  assert.match(scope.warning, /admin peer/)
})

test('deriveScopeFromInterfaces: no interface in 10.200.0.0/16 -> user-actionable error', () => {
  const interfaces = {
    eth0: [{ address: '192.168.1.50', family: 'IPv4', internal: false }],
    lo: [{ address: '127.0.0.1', family: 'IPv4', internal: true }]
  }
  assert.throws(() => deriveScopeFromInterfaces(interfaces), (err) => {
    assert.ok(err instanceof ScopeError)
    assert.match(err.message, /don't see.*tunnel/)
    assert.match(err.message, /--conf/)
    assert.match(err.message, /--cidr/)
    return true
  })
})

test('deriveScopeFromInterfaces: several interfaces in 10.200.0.0/16 -> error listing candidates', () => {
  const interfaces = {
    wg0: [{ address: '10.200.3.2', family: 'IPv4', internal: false }],
    wg1: [{ address: '10.200.9.2', family: 'IPv4', internal: false }]
  }
  assert.throws(() => deriveScopeFromInterfaces(interfaces), (err) => {
    assert.ok(err instanceof ScopeError)
    assert.match(err.message, /several interfaces/)
    assert.match(err.message, /10\.200\.3\.2/)
    assert.match(err.message, /10\.200\.9\.2/)
    assert.match(err.message, /--conf/)
    return true
  })
})

test('deriveScopeFromInterfaces: address in overlay but no recognized pattern -> error', () => {
  const interfaces = { wg0: [{ address: '10.200.5.9', family: 'IPv4', internal: false }] }
  assert.throws(() => deriveScopeFromInterfaces(interfaces), ScopeError)
})

test('resolveScope: --cidr wins over everything else (S1)', () => {
  const scope = resolveScope({ cidrArg: '10.1.2.0/24, 10.3.4.0/24', confPath: '/never/read.conf' })
  assert.deepEqual(scope.cidrs, ['10.1.2.0/24', '10.3.4.0/24'])
  assert.equal(scope.origin, '--cidr')
})

test('resolveScope: --conf wins over automatic derivation (S2)', () => {
  const scope = resolveScope({
    confPath: 'team9.conf',
    readFile: () => 'AllowedIPs = 10.60.9.0/24, 10.50.0.0/24, 10.51.0.0/24\n'
  })
  assert.deepEqual(scope.cidrs, ['10.60.9.0/24', '10.50.0.0/24', '10.51.0.0/24'])
  assert.match(scope.origin, /--conf team9\.conf/)
})

test('resolveScope: without --cidr or --conf uses interfaces (S3)', () => {
  const interfaces = { wg0: [{ address: '10.200.2.2', family: 'IPv4', internal: false }] }
  const scope = resolveScope({ interfaces })
  assert.deepEqual(scope.cidrs, ['10.60.2.0/24', '10.50.0.0/24', '10.51.0.0/24'])
})

test('ipInCidr: inside and outside a /24', () => {
  assert.ok(ipInCidr('10.60.3.4', '10.60.3.0/24'))
  assert.ok(!ipInCidr('10.60.4.4', '10.60.3.0/24'))
})

test('ipInCidr: does not crash with IPs whose first octet is >= 128 (sign bit)', () => {
  assert.ok(ipInCidr('203.0.113.5', '203.0.113.0/24'))
  assert.ok(!ipInCidr('203.0.114.5', '203.0.113.0/24'))
})

test('hostsInCidr: /24 excludes network and broadcast (254 usable hosts)', () => {
  const hosts = [...hostsInCidr('10.60.3.0/24')]
  assert.equal(hosts.length, 254)
  assert.ok(!hosts.includes('10.60.3.0'))
  assert.ok(!hosts.includes('10.60.3.255'))
  assert.equal(hosts[0], '10.60.3.1')
  assert.equal(hosts.at(-1), '10.60.3.254')
})

test('hostsInCidr: /32 is a single host, no exclusions', () => {
  assert.deepEqual([...hostsInCidr('10.60.3.4/32')], ['10.60.3.4'])
})

test('hostsInCidr: /32 with first octet >= 128 does not crash (sign bit bug regression)', () => {
  assert.deepEqual([...hostsInCidr('203.0.113.5/32')], ['203.0.113.5'])
})

test('cidrHostCount matches hostsInCidr', () => {
  assert.equal(cidrHostCount('10.60.3.0/24'), 254)
  assert.equal(cidrHostCount('10.60.3.4/32'), 1)
})

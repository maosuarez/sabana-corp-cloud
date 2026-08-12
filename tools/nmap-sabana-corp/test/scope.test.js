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

test('parseAllowedIps: separados por coma y espacio', () => {
  const conf = `[Interface]\nAddress = 10.200.3.2/32\n\n[Peer]\nAllowedIPs = 10.60.3.0/24, 10.50.0.0/24, 10.51.0.0/24\n`
  assert.deepEqual(parseAllowedIps(conf), ['10.60.3.0/24', '10.50.0.0/24', '10.51.0.0/24'])
})

test('parseAllowedIps: sin espacios y con espacios extra alrededor del =', () => {
  const conf = 'AllowedIPs=10.60.7.0/24,10.50.0.0/24,10.51.0.0/24'
  assert.deepEqual(parseAllowedIps(conf), ['10.60.7.0/24', '10.50.0.0/24', '10.51.0.0/24'])

  const spaced = 'AllowedIPs   =   10.60.7.0/24 , 10.50.0.0/24 ,10.51.0.0/24'
  assert.deepEqual(parseAllowedIps(spaced), ['10.60.7.0/24', '10.50.0.0/24', '10.51.0.0/24'])
})

test('parseAllowedIps: sin linea AllowedIPs -> ScopeError', () => {
  assert.throws(() => parseAllowedIps('[Interface]\nAddress = 10.200.3.2/32\n'), ScopeError)
})

test('teamFromTunnelAddress: 10.200.N.2 -> equipo N', () => {
  assert.equal(teamFromTunnelAddress('10.200.7.2'), 7)
  assert.equal(teamFromTunnelAddress('10.200.42.2'), 42)
})

test('teamFromTunnelAddress: 10.200.0.2 -> admin (null)', () => {
  assert.equal(teamFromTunnelAddress('10.200.0.2'), null)
})

test('teamFromTunnelAddress: direccion que no encaja -> undefined', () => {
  assert.equal(teamFromTunnelAddress('10.200.7.5'), undefined)
  assert.equal(teamFromTunnelAddress('10.60.7.2'), undefined)
})

test('deriveScopeFromInterfaces: interfaz 10.200.7.2 -> team7 + ambas DMZ', () => {
  const interfaces = {
    wg0: [{ address: '10.200.7.2', family: 'IPv4', internal: false }],
    lo: [{ address: '127.0.0.1', family: 'IPv4', internal: true }]
  }
  const scope = deriveScopeFromInterfaces(interfaces)
  assert.deepEqual(scope.cidrs, ['10.60.7.0/24', '10.50.0.0/24', '10.51.0.0/24'])
  assert.equal(scope.warning, null)
  assert.match(scope.origin, /10\.200\.7\.2/)
})

test('deriveScopeFromInterfaces: peer admin (10.200.0.2) -> solo DMZ + warning', () => {
  const interfaces = { utun4: [{ address: '10.200.0.2', family: 'IPv4', internal: false }] }
  const scope = deriveScopeFromInterfaces(interfaces)
  assert.deepEqual(scope.cidrs, ['10.50.0.0/24', '10.51.0.0/24'])
  assert.match(scope.warning, /peer admin/)
})

test('deriveScopeFromInterfaces: sin interfaz en 10.200.0.0/16 -> error accionable', () => {
  const interfaces = {
    eth0: [{ address: '192.168.1.50', family: 'IPv4', internal: false }],
    lo: [{ address: '127.0.0.1', family: 'IPv4', internal: true }]
  }
  assert.throws(() => deriveScopeFromInterfaces(interfaces), (err) => {
    assert.ok(err instanceof ScopeError)
    assert.match(err.message, /no veo un tunel/)
    assert.match(err.message, /--conf/)
    assert.match(err.message, /--cidr/)
    return true
  })
})

test('deriveScopeFromInterfaces: varias interfaces en 10.200.0.0/16 -> error listando candidatas', () => {
  const interfaces = {
    wg0: [{ address: '10.200.3.2', family: 'IPv4', internal: false }],
    wg1: [{ address: '10.200.9.2', family: 'IPv4', internal: false }]
  }
  assert.throws(() => deriveScopeFromInterfaces(interfaces), (err) => {
    assert.ok(err instanceof ScopeError)
    assert.match(err.message, /varias interfaces/)
    assert.match(err.message, /10\.200\.3\.2/)
    assert.match(err.message, /10\.200\.9\.2/)
    assert.match(err.message, /--conf/)
    return true
  })
})

test('deriveScopeFromInterfaces: direccion en el overlay pero sin patron reconocido -> error', () => {
  const interfaces = { wg0: [{ address: '10.200.5.9', family: 'IPv4', internal: false }] }
  assert.throws(() => deriveScopeFromInterfaces(interfaces), ScopeError)
})

test('resolveScope: --cidr gana sobre todo lo demas (S1)', () => {
  const scope = resolveScope({ cidrArg: '10.1.2.0/24, 10.3.4.0/24', confPath: '/nunca/leido.conf' })
  assert.deepEqual(scope.cidrs, ['10.1.2.0/24', '10.3.4.0/24'])
  assert.equal(scope.origin, '--cidr')
})

test('resolveScope: --conf gana sobre la derivacion automatica (S2)', () => {
  const scope = resolveScope({
    confPath: 'team9.conf',
    readFile: () => 'AllowedIPs = 10.60.9.0/24, 10.50.0.0/24, 10.51.0.0/24\n'
  })
  assert.deepEqual(scope.cidrs, ['10.60.9.0/24', '10.50.0.0/24', '10.51.0.0/24'])
  assert.match(scope.origin, /--conf team9\.conf/)
})

test('resolveScope: sin --cidr ni --conf usa las interfaces (S3)', () => {
  const interfaces = { wg0: [{ address: '10.200.2.2', family: 'IPv4', internal: false }] }
  const scope = resolveScope({ interfaces })
  assert.deepEqual(scope.cidrs, ['10.60.2.0/24', '10.50.0.0/24', '10.51.0.0/24'])
})

test('ipInCidr: dentro y fuera de un /24', () => {
  assert.ok(ipInCidr('10.60.3.4', '10.60.3.0/24'))
  assert.ok(!ipInCidr('10.60.4.4', '10.60.3.0/24'))
})

test('ipInCidr: no revienta con IPs cuyo primer octeto es >= 128 (bit de signo)', () => {
  assert.ok(ipInCidr('203.0.113.5', '203.0.113.0/24'))
  assert.ok(!ipInCidr('203.0.114.5', '203.0.113.0/24'))
})

test('hostsInCidr: /24 excluye red y broadcast (254 hosts utiles)', () => {
  const hosts = [...hostsInCidr('10.60.3.0/24')]
  assert.equal(hosts.length, 254)
  assert.ok(!hosts.includes('10.60.3.0'))
  assert.ok(!hosts.includes('10.60.3.255'))
  assert.equal(hosts[0], '10.60.3.1')
  assert.equal(hosts.at(-1), '10.60.3.254')
})

test('hostsInCidr: /32 es un unico host, sin exclusiones', () => {
  assert.deepEqual([...hostsInCidr('10.60.3.4/32')], ['10.60.3.4'])
})

test('hostsInCidr: /32 con primer octeto >= 128 no explota (regresion del bug de signo)', () => {
  assert.deepEqual([...hostsInCidr('203.0.113.5/32')], ['203.0.113.5'])
})

test('cidrHostCount coincide con hostsInCidr', () => {
  assert.equal(cidrHostCount('10.60.3.0/24'), 254)
  assert.equal(cidrHostCount('10.60.3.4/32'), 1)
})

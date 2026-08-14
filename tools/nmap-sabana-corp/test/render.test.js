import assert from 'node:assert/strict'
import { test } from 'node:test'
import { renderJson, renderText } from '../src/render.js'

function sampleData(overrides = {}) {
  return {
    version: '1.0.0',
    scope: { cidrs: ['10.60.3.0/24', '10.50.0.0/24'], origin: 'tunnel interface 10.200.3.2', warning: null },
    resolver: { ip: '10.200.0.1', up: true },
    hosts: [
      { ip: '10.60.3.4', cidr: '10.60.3.0/24', fqdn: 'database.team3.sabanacorp.internal', ports: [{ port: 3306, proto: 'tcp', service: 'mysql' }] },
      { ip: '10.60.3.7', cidr: '10.60.3.0/24', fqdn: null, ports: [{ port: 80, proto: 'tcp', service: 'http' }] }
    ],
    stats: { addressesScanned: 508, portsOpen: 2, elapsedMs: 6200 },
    ...overrides
  }
}

test('renderText: includes scope, origin, and names header', () => {
  const text = renderText(sampleData())
  assert.match(text, /scope    : 10\.60\.3\.0\/24, 10\.50\.0\.0\/24/)
  assert.match(text, /source: tunnel interface 10\.200\.3\.2/)
  assert.match(text, /names    : 10\.200\.0\.1 \(lab resolver, up\)/)
})

test('renderText: each host falls under its CIDR section with FQDN or "-"', () => {
  const text = renderText(sampleData())
  assert.match(text, /-- 10\.60\.3\.0\/24/)
  assert.match(text, /10\.60\.3\.4\s+database\.team3\.sabanacorp\.internal\s+3306\/tcp mysql/)
  assert.match(text, /10\.60\.3\.7\s+-\s+80\/tcp http/)
})

test('renderText: note about hosts without FQDN only if resolver is up', () => {
  const withResolver = renderText(sampleData())
  assert.match(withResolver, /1 hosts without FQDN/)

  const resolverDown = renderText(sampleData({ resolver: { ip: '10.200.0.1', up: false } }))
  assert.match(resolverDown, /no response -- showing IPs only/)
  assert.ok(!resolverDown.includes('hosts without FQDN'))
})

test('renderText: 0 hosts alive prints the verification message, not an error', () => {
  const text = renderText(sampleData({ hosts: [], stats: { addressesScanned: 762, portsOpen: 0, elapsedMs: 4000 } }))
  assert.match(text, /0 hosts alive/)
  assert.match(text, /verify your tunnel/)
})

test('renderText: never prints banners, service version, or host role', () => {
  const text = renderText(sampleData())
  for (const forbidden of ['banner', 'CVE', 'version:', 'role:', 'challenge', 'decoy']) {
    assert.ok(!text.toLowerCase().includes(forbidden.toLowerCase()), `should not contain "${forbidden}"`)
  }
})

test('renderJson: same fields as table, no hidden extras', () => {
  const data = JSON.parse(renderJson(sampleData()))
  assert.deepEqual(Object.keys(data).sort(), ['hosts', 'resolver', 'scope', 'stats', 'version'])
  assert.deepEqual(Object.keys(data.hosts[0]).sort(), ['cidr', 'fqdn', 'ip', 'ports'])
  assert.equal(data.hosts[0].ports[0].service, 'mysql')
  assert.equal(data.stats.hostsAlive, 2)
})

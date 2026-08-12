import assert from 'node:assert/strict'
import { test } from 'node:test'
import { renderJson, renderText } from '../src/render.js'

function sampleData(overrides = {}) {
  return {
    version: '1.0.0',
    scope: { cidrs: ['10.60.3.0/24', '10.50.0.0/24'], origin: 'interfaz de tunel 10.200.3.2', warning: null },
    resolver: { ip: '10.200.0.1', up: true },
    hosts: [
      { ip: '10.60.3.4', cidr: '10.60.3.0/24', fqdn: 'database.team3.sabanacorp.internal', ports: [{ port: 3306, proto: 'tcp', service: 'mysql' }] },
      { ip: '10.60.3.7', cidr: '10.60.3.0/24', fqdn: null, ports: [{ port: 80, proto: 'tcp', service: 'http' }] }
    ],
    stats: { addressesScanned: 508, portsOpen: 2, elapsedMs: 6200 },
    ...overrides
  }
}

test('renderText: incluye alcance, origen y encabezado de nombres', () => {
  const text = renderText(sampleData())
  assert.match(text, /alcance : 10\.60\.3\.0\/24, 10\.50\.0\.0\/24/)
  assert.match(text, /origen: interfaz de tunel 10\.200\.3\.2/)
  assert.match(text, /nombres : 10\.200\.0\.1 \(resolutor del lab, activo\)/)
})

test('renderText: cada host cae bajo su seccion de CIDR con FQDN o "-"', () => {
  const text = renderText(sampleData())
  assert.match(text, /-- 10\.60\.3\.0\/24/)
  assert.match(text, /10\.60\.3\.4\s+database\.team3\.sabanacorp\.internal\s+3306\/tcp mysql/)
  assert.match(text, /10\.60\.3\.7\s+-\s+80\/tcp http/)
})

test('renderText: nota de hosts sin FQDN solo si el resolutor esta activo', () => {
  const withResolver = renderText(sampleData())
  assert.match(withResolver, /1 hosts sin FQDN/)

  const resolverDown = renderText(sampleData({ resolver: { ip: '10.200.0.1', up: false } }))
  assert.match(resolverDown, /sin respuesta -- mostrando solo IPs/)
  assert.ok(!resolverDown.includes('hosts sin FQDN'))
})

test('renderText: 0 hosts vivos imprime el mensaje de verificacion, no un error', () => {
  const text = renderText(sampleData({ hosts: [], stats: { addressesScanned: 762, portsOpen: 0, elapsedMs: 4000 } }))
  assert.match(text, /0 hosts vivos/)
  assert.match(text, /verifica tu tunel/)
})

test('renderText: nunca imprime banners, version de servicio o rol del host', () => {
  const text = renderText(sampleData())
  for (const forbidden of ['banner', 'CVE', 'version:', 'role:', 'reto', 'decoy']) {
    assert.ok(!text.toLowerCase().includes(forbidden.toLowerCase()), `no deberia contener "${forbidden}"`)
  }
})

test('renderJson: mismos campos que la tabla, sin extras ocultos', () => {
  const data = JSON.parse(renderJson(sampleData()))
  assert.deepEqual(Object.keys(data).sort(), ['hosts', 'resolver', 'scope', 'stats', 'version'])
  assert.deepEqual(Object.keys(data.hosts[0]).sort(), ['cidr', 'fqdn', 'ip', 'ports'])
  assert.equal(data.hosts[0].ports[0].service, 'mysql')
  assert.equal(data.stats.hostsAlive, 2)
})

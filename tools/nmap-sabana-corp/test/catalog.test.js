import assert from 'node:assert/strict'
import { test } from 'node:test'
import { CATALOG_PORTS, PHASE_A_PORTS, serviceForPort } from '../src/catalog.js'

test('catalogo de puertos coincide con el documentado en el plan', () => {
  assert.deepEqual(CATALOG_PORTS, [
    21, 22, 25, 80, 110, 143, 443, 445, 554, 873, 3000, 3306, 5432, 8000, 8080, 8443, 9090, 9100, 9418
  ])
})

test('Fase A es un subconjunto del catalogo completo', () => {
  for (const port of PHASE_A_PORTS) assert.ok(CATALOG_PORTS.includes(port))
})

test('serviceForPort: etiquetas conocidas del ejemplo del plan', () => {
  assert.equal(serviceForPort(3306), 'mysql')
  assert.equal(serviceForPort(80), 'http')
  assert.equal(serviceForPort(22), 'ssh')
  assert.equal(serviceForPort(8080), 'http-alt')
  assert.equal(serviceForPort(9100), 'jetdirect')
})

test('serviceForPort: puerto fuera de catalogo no revienta', () => {
  assert.equal(serviceForPort(65000), 'unknown')
})

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { CATALOG_PORTS, PHASE_A_PORTS, serviceForPort } from '../src/catalog.js'

test('port catalog matches what is documented in the plan', () => {
  assert.deepEqual(CATALOG_PORTS, [
    21, 22, 25, 80, 110, 143, 443, 445, 554, 873, 3000, 3306, 5432, 8000, 8080, 8443, 9090, 9100, 9418
  ])
})

test('Phase A is a subset of the complete catalog', () => {
  for (const port of PHASE_A_PORTS) assert.ok(CATALOG_PORTS.includes(port))
})

test('serviceForPort: known labels from the plan example', () => {
  assert.equal(serviceForPort(3306), 'mysql')
  assert.equal(serviceForPort(80), 'http')
  assert.equal(serviceForPort(22), 'ssh')
  assert.equal(serviceForPort(8080), 'http-alt')
  assert.equal(serviceForPort(9100), 'jetdirect')
})

test('serviceForPort: port outside catalog does not crash', () => {
  assert.equal(serviceForPort(65000), 'unknown')
})

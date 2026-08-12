import assert from 'node:assert/strict'
import { test } from 'node:test'
import { runPool, scan } from '../src/scan.js'

test('runPool: respeta el limite de concurrencia', async () => {
  let active = 0
  let maxActive = 0
  const items = Array.from({ length: 10 }, (_, i) => i)

  await runPool(
    items,
    async () => {
      active++
      maxActive = Math.max(maxActive, active)
      await new Promise((resolve) => setTimeout(resolve, 10))
      active--
    },
    3
  )

  assert.ok(maxActive <= 3, `maxActive fue ${maxActive}, esperaba <= 3`)
})

test('runPool: preserva el resultado en el orden de entrada', async () => {
  const items = [3, 1, 2]
  const results = await runPool(items, async (n) => n * 10, 2)
  assert.deepEqual(results, [30, 10, 20])
})

test('runPool: items vacios no revientan', async () => {
  const results = await runPool([], async (n) => n, 5)
  assert.deepEqual(results, [])
})

test('scan: contra loopback, un host sin puertos del catalogo abiertos sigue vivo (RST cuenta)', async () => {
  const result = await scan({ cidrs: ['127.0.0.1/32'] })
  assert.equal(result.hosts.length, 1)
  assert.equal(result.hosts[0].ip, '127.0.0.1')
  assert.equal(result.addressesScanned, 1)
})

test('scan: hostsInCidr inyectable para pruebas sin abrir sockets reales de mas', async () => {
  const result = await scan({
    cidrs: ['10.60.99.0/24'],
    hostsInCidr: function* () {
      yield '127.0.0.1'
    }
  })
  assert.equal(result.addressesScanned, 1)
})

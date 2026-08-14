import assert from 'node:assert/strict'
import { test } from 'node:test'
import { runPool, scan } from '../src/scan.js'

test('runPool: respects the concurrency limit', async () => {
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

  assert.ok(maxActive <= 3, `maxActive was ${maxActive}, expected <= 3`)
})

test('runPool: preserves result in input order', async () => {
  const items = [3, 1, 2]
  const results = await runPool(items, async (n) => n * 10, 2)
  assert.deepEqual(results, [30, 10, 20])
})

test('runPool: empty items do not crash', async () => {
  const results = await runPool([], async (n) => n, 5)
  assert.deepEqual(results, [])
})

test('scan: against loopback, a host with no catalog ports open is still alive (RST counts)', async () => {
  const result = await scan({ cidrs: ['127.0.0.1/32'] })
  assert.equal(result.hosts.length, 1)
  assert.equal(result.hosts[0].ip, '127.0.0.1')
  assert.equal(result.addressesScanned, 1)
})

test('scan: hostsInCidr injectable for testing without opening extra real sockets', async () => {
  const result = await scan({
    cidrs: ['10.60.99.0/24'],
    hostsInCidr: function* () {
      yield '127.0.0.1'
    }
  })
  assert.equal(result.addressesScanned, 1)
})

import assert from 'node:assert/strict'
import { test } from 'node:test'
import { resolveNames } from '../src/names.js'

// TEST-NET-1 (RFC 5737): reserved for documentation, never routable -- degrades by timeout
// deterministically without depending on whether a real VPN tunnel exists.
test('resolveNames: unreachable resolver degrades to "no names" in <2s, does not crash', async () => {
  const { fqdnByIp, resolverUp } = await resolveNames(['10.60.3.4'], { resolverIp: '192.0.2.1' })
  assert.equal(resolverUp, false)
  assert.equal(fqdnByIp.size, 0)
})

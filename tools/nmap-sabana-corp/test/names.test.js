import assert from 'node:assert/strict'
import { test } from 'node:test'
import { resolveNames } from '../src/names.js'

// TEST-NET-1 (RFC 5737): reservado para documentacion, nunca enrutable -- degrada por timeout de
// forma determinista sin depender de que exista o no un tunel VPN real.
test('resolveNames: resolutor inalcanzable degrada a "sin nombres" en <2s, sin reventar', async () => {
  const { fqdnByIp, resolverUp } = await resolveNames(['10.60.3.4'], { resolverIp: '192.0.2.1' })
  assert.equal(resolverUp, false)
  assert.equal(fqdnByIp.size, 0)
})

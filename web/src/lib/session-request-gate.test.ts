import { expect, it, vi } from 'vitest'
import { createFakeApi } from '../test/fake-api'
import { createSessionRequestGate } from './session-request-gate'

it('never sends requests based on a cached identity before verification', async () => {
  const read = vi.fn().mockResolvedValue({ sessions: [] })
  const gate = createSessionRequestGate(createFakeApi({ listSessions: read }))
  const request = gate.api.listSessions()
  await Promise.resolve()
  expect(read).not.toHaveBeenCalled()
  gate.setReady(true)
  await request
  expect(read).toHaveBeenCalledOnce()
})
it('cancels pending requests when the cached session is invalidated', async () => {
  const read = vi.fn()
  const gate = createSessionRequestGate(createFakeApi({ listSessions: read }))
  const request = gate.api.listSessions()
  const rejected = expect(request).rejects.toMatchObject({ name: 'AbortError' })
  gate.dispose()
  await rejected
  expect(read).not.toHaveBeenCalled()
})
it('does not dispatch when verification is revoked before a queued continuation runs', async () => {
  const read = vi.fn().mockResolvedValue({ sessions: [] })
  const gate = createSessionRequestGate(createFakeApi({ listSessions: read }))
  gate.setReady(true)
  const request = gate.api.listSessions()
  gate.setReady(false)
  await Promise.resolve()
  expect(read).not.toHaveBeenCalled()
  gate.setReady(true)
  await request
  expect(read).toHaveBeenCalledOnce()
})

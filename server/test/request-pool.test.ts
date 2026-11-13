import { describe, it, expect, vi } from 'vitest'
import type { ExecutionContext } from 'hono'
import { serveFetch, withRequestPool } from '../src/index'
import { createApp } from '../src/app'
import type { LlmClient } from '../src/dj/llm'
import { user } from '../src/db/schema'
import { createTestDb } from './helpers/db'
import { eventsOnly, readSse } from './helpers/sse'

// Spec 2026-11-13 dj-turn-steps, "Pool lifetime": a streamed turn outlives
// app.fetch, so the request's Neon pool must stay open until the work the
// request handed to waitUntil has settled, and close as soon as it can when
// there is none.

function deferred() {
  let resolve!: () => void
  let reject!: (e: unknown) => void
  const promise = new Promise<void>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

// Stands in for the platform's context. Its methods insist on being called
// on the context itself, as the runtime's native ones do.
function platformCtx() {
  const waited: Promise<unknown>[] = []
  const passed: unknown[] = []
  const ctx: ExecutionContext = {
    waitUntil(this: unknown, p: Promise<unknown>) {
      if (this !== ctx) throw new TypeError('Illegal invocation')
      waited.push(p)
    },
    passThroughOnException(this: unknown) {
      if (this !== ctx) throw new TypeError('Illegal invocation')
      passed.push(this)
    },
    props: { worker: 'mixtape' },
  }
  return { ctx, waited, passed }
}

function fakePool() {
  return { end: vi.fn(async () => {}) }
}

describe('withRequestPool', () => {
  it('a request that records nothing ends the pool at once, as before', async () => {
    const { ctx, waited } = platformCtx()
    const pool = fakePool()

    const res = await withRequestPool(ctx, pool, async () => new Response('ok'))

    expect(await res.text()).toBe('ok')
    expect(pool.end).toHaveBeenCalledTimes(1)
    expect(waited).toHaveLength(1)
  })

  it('a recorded waitUntil promise delays pool.end until it settles, and still reaches the platform', async () => {
    const { ctx, waited } = platformCtx()
    const pool = fakePool()
    const turn = deferred()

    await withRequestPool(ctx, pool, async (requestCtx) => {
      requestCtx.waitUntil(turn.promise)
      return new Response('streaming')
    })

    expect(waited[0]).toBe(turn.promise)
    expect(waited).toHaveLength(2)
    await new Promise((r) => setTimeout(r, 10))
    expect(pool.end).not.toHaveBeenCalled()
    turn.resolve()
    await waited[1]
    expect(pool.end).toHaveBeenCalledTimes(1)
  })

  it('waits for every recorded promise, and a rejected one still ends the pool', async () => {
    const { ctx, waited } = platformCtx()
    const pool = fakePool()
    const first = deferred()
    const second = deferred()

    await withRequestPool(ctx, pool, async (requestCtx) => {
      requestCtx.waitUntil(first.promise)
      requestCtx.waitUntil(second.promise)
      return new Response('')
    })

    first.reject(new Error('turn failed'))
    await new Promise((r) => setTimeout(r, 10))
    expect(pool.end).not.toHaveBeenCalled()
    second.resolve()
    await waited[waited.length - 1]
    expect(pool.end).toHaveBeenCalledTimes(1)
  })

  it('a handler that throws still ends the pool', async () => {
    const { ctx } = platformCtx()
    const pool = fakePool()

    await expect(withRequestPool(ctx, pool, async () => {
      throw new Error('misconfigured binding')
    })).rejects.toThrow('misconfigured binding')

    expect(pool.end).toHaveBeenCalledTimes(1)
  })

  it("forwards the context's other members: passThroughOnException on the platform context, props", async () => {
    const { ctx, passed } = platformCtx()

    await withRequestPool(ctx, fakePool(), async (requestCtx) => {
      requestCtx.passThroughOnException()
      expect(requestCtx.props).toEqual({ worker: 'mixtape' })
      expect('passThroughOnException' in requestCtx).toBe(true)
      return new Response('')
    })

    expect(passed).toEqual([ctx])
  })
})

// The fetch handler's own wiring: the app must get the recording context,
// or every streamed turn would run with its pool already ended.
describe('serveFetch', () => {
  async function wiring(llm: LlmClient) {
    const db = await createTestDb()
    await db.insert(user).values({ id: 'u1', name: 'u1', email: 'u1@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
    const pool = fakePool()
    const embed = async () => Array.from({ length: 1024 }, (_, i) => (i === 0 ? 1 : 0))
    return {
      pool,
      openDb: () => ({ db, pool }),
      buildApp: () => createApp({
        auth: { handler: () => new Response('ok'), api: { getSession: async () => ({ user: { id: 'u1' } }) } },
        db,
        dj: { deps: { llm, embed } },
      }),
    }
  }

  it('a streamed turn keeps the pool open until the turn has ended', async () => {
    vi.spyOn(console, 'log').mockImplementation(() => {})
    const gate = deferred()
    const llm: LlmClient = async () => {
      await gate.promise
      return { text: 'ready.', toolCalls: [], raw: [{ type: 'text', text: 'ready.' }], stopReason: 'end_turn', usage: null }
    }
    const { pool, ...rest } = await wiring(llm)
    const { ctx, waited } = platformCtx()

    const res = await serveFetch(new Request('http://x/sessions', {
      method: 'POST',
      headers: { 'content-type': 'application/json', accept: 'text/event-stream' },
      body: JSON.stringify({ prompt: 'hello' }),
    }), {}, ctx, rest)

    expect(res.headers.get('content-type')).toBe('text/event-stream; charset=utf-8')
    await new Promise((r) => setTimeout(r, 20))
    expect(pool.end).not.toHaveBeenCalled()
    gate.resolve()
    expect(eventsOnly(await readSse(res)).map((e) => e.event)).toEqual(['session', 'result'])
    await waited[waited.length - 1]
    expect(pool.end).toHaveBeenCalledTimes(1)
    vi.restoreAllMocks()
  })

  it('a request that hands nothing to waitUntil ends the pool at once', async () => {
    const { pool, ...rest } = await wiring(async () => {
      throw new Error('no model call expected')
    })
    const { ctx } = platformCtx()

    const res = await serveFetch(new Request('http://x/health'), {}, ctx, rest)

    expect(res.status).toBe(200)
    expect(pool.end).toHaveBeenCalledTimes(1)
  })
})

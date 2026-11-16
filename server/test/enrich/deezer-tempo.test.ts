import { describe, it, expect } from 'vitest'
import { createDeezerTempoClient } from '../../src/enrich/deezer-tempo'
import { EnrichSourceError, type FetchLike } from '../../src/enrich/types'

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status })

function recording(respond: (url: string, init?: RequestInit) => Promise<Response> | Response) {
  const calls: { url: string; init?: RequestInit }[] = []
  const fetchLike: FetchLike = async (url, init) => {
    calls.push({ url: String(url), init })
    return respond(String(url), init)
  }
  return { calls, client: createDeezerTempoClient({ fetchLike }) }
}

async function transientError(p: Promise<unknown>): Promise<EnrichSourceError> {
  const e = await p.then(() => null, (err: unknown) => err)
  expect(e).toBeInstanceOf(EnrichSourceError)
  const err = e as EnrichSourceError
  expect(err.source).toBe('deezer')
  expect(err.transient).toBe(true)
  return err
}

describe('createDeezerTempoClient', () => {
  it('returns bpm on a hit, with a timeout signal', async () => {
    const { calls, client } = recording(() => json({ id: 1, isrc: 'GBAYE0601498', bpm: 121.4 }))
    expect(await client.tempoByIsrc('GBAYE0601498')).toBe(121.4)
    expect(calls).toHaveLength(1)
    expect(calls[0].url).toBe('https://api.deezer.com/track/isrc:GBAYE0601498')
    expect(calls[0].init?.signal).toBeInstanceOf(AbortSignal)
  })

  it('uppercases and trims the ISRC in the URL', async () => {
    const { calls, client } = recording(() => json({ bpm: 100 }))
    await client.tempoByIsrc('  gbaye0601498 ')
    expect(calls[0].url).toBe('https://api.deezer.com/track/isrc:GBAYE0601498')
  })

  it('makes no request for an empty or invalid ISRC', async () => {
    const { calls, client } = recording(() => json({ bpm: 100 }))
    expect(await client.tempoByIsrc('')).toBeNull()
    expect(await client.tempoByIsrc('   ')).toBeNull()
    expect(await client.tempoByIsrc('not-an-isrc')).toBeNull()
    expect(calls).toHaveLength(0)
  })

  it('returns null for bpm 0', async () => {
    const { client } = recording(() => json({ bpm: 0 }))
    expect(await client.tempoByIsrc('GBAYE0601498')).toBeNull()
  })

  it('returns null when bpm is missing or not a number', async () => {
    const { client: missing } = recording(() => json({ id: 1 }))
    expect(await missing.tempoByIsrc('GBAYE0601498')).toBeNull()
    const { client: str } = recording(() => json({ bpm: '120' }))
    expect(await str.tempoByIsrc('GBAYE0601498')).toBeNull()
  })

  it("returns null for Deezer's 200 error body", async () => {
    const { client } = recording(() =>
      json({ error: { type: 'DataException', message: 'no data', code: 800 } }))
    expect(await client.tempoByIsrc('GBAYE0601498')).toBeNull()
  })

  it('returns null for bpm outside 40-250', async () => {
    const { client: low } = recording(() => json({ bpm: 39.9 }))
    expect(await low.tempoByIsrc('GBAYE0601498')).toBeNull()
    const { client: high } = recording(() => json({ bpm: 250.1 }))
    expect(await high.tempoByIsrc('GBAYE0601498')).toBeNull()
    const { client: edge } = recording(() => json({ bpm: 40 }))
    expect(await edge.tempoByIsrc('GBAYE0601498')).toBe(40)
  })

  it('throws a transient error on 500', async () => {
    const { client } = recording(() => new Response('', { status: 500 }))
    const err = await transientError(client.tempoByIsrc('GBAYE0601498'))
    expect(err.status).toBe(500)
  })

  it('throws a transient error on 429', async () => {
    const { client } = recording(() => new Response('', { status: 429 }))
    const err = await transientError(client.tempoByIsrc('GBAYE0601498'))
    expect(err.status).toBe(429)
  })

  it('throws a transient error on timeout or abort', async () => {
    const { client: timeout } = recording(() => {
      throw new DOMException('timed out', 'TimeoutError')
    })
    await transientError(timeout.tempoByIsrc('GBAYE0601498'))
    const { client: abort } = recording(() => {
      throw new DOMException('aborted', 'AbortError')
    })
    await transientError(abort.tempoByIsrc('GBAYE0601498'))
  })

  it('throws a transient error when fetch rejects', async () => {
    const { client } = recording(() => {
      throw new TypeError('network down')
    })
    await transientError(client.tempoByIsrc('GBAYE0601498'))
  })

  it('throws a transient error on a non-JSON body', async () => {
    const { client } = recording(() => new Response('<html>busy</html>', { status: 200 }))
    await transientError(client.tempoByIsrc('GBAYE0601498'))
  })

  it('returns null on 404 and other 4xx', async () => {
    const { client: notFound } = recording(() => new Response('', { status: 404 }))
    expect(await notFound.tempoByIsrc('GBAYE0601498')).toBeNull()
    const { client: forbidden } = recording(() => new Response('', { status: 403 }))
    expect(await forbidden.tempoByIsrc('GBAYE0601498')).toBeNull()
  })
})

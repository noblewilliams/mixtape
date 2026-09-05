import { describe, expect, it, vi } from 'vitest'
import { createAppleCatalogClient, type FetchLike } from '../../src/musickit/catalog'

const ISRC = 'USUG11904206'
const OTHER = 'GBUM71029604'
const song = (id = '123', isrc = ISRC) => ({
  id, type: 'songs', attributes: { name: 'Song', artistName: 'Artist', isrc },
})
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status })
function client(fetchLike: FetchLike) {
  return createAppleCatalogClient({
    fetchLike, issueServerToken: async () => ({ developerToken: 'private-token', expiresAt: Date.now() / 1000 + 3600 }),
  })
}

describe('Apple catalog ISRC lookup', () => {
  it('looks up normalized exact ISRCs and retains multiple catalog matches', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => json({ data: [song(), song('456'), song('789', OTHER)] }))
    const result = await client(fetchLike).getSongsByIsrc('ng', [ISRC.toLowerCase(), ISRC])
    expect(result.get(ISRC)?.map((value) => value.appleId)).toEqual(['123', '456'])
    expect(result.has(OTHER)).toBe(false)
    const [input, init] = fetchLike.mock.calls[0]
    const url = new URL(input)
    expect(url.origin).toBe('https://api.music.apple.com')
    expect(url.pathname).toBe('/v1/catalog/ng/songs')
    expect(url.searchParams.get('filter[isrc]')).toBe(ISRC)
    expect(url.searchParams.has('ids')).toBe(false)
    expect(new Headers(init?.headers).get('Authorization')).toBe('Bearer private-token')
  })

  it('batches at 25 codes and skips invalid input before any request', async () => {
    const fetchLike = vi.fn<FetchLike>(async () => json({ data: [] }))
    const catalog = client(fetchLike)
    await catalog.getSongsByIsrc('ng', ['bad', 'US-UG1-19-04206'])
    expect(fetchLike).not.toHaveBeenCalled()
    const codes = Array.from({ length: 26 }, (_, i) => `USUG1${String(i).padStart(7, '0')}`)
    await catalog.getSongsByIsrc('gb', codes)
    expect(fetchLike.mock.calls.map(([input]) => new URL(input).searchParams.get('filter[isrc]')?.split(',').length))
      .toEqual([25, 1])
  })

  it.each([
    ['a missing ISRC', { data: [song(), song('456', '')] }],
    ['a malformed song', { data: [song(), { id: '456', type: 'songs', attributes: { isrc: ISRC } }] }],
    ['an invalid catalog ID', { data: [song('bad/id')] }],
    ['a duplicate catalog ID', { data: [song(), song()] }],
    ['pagination', { data: [song()], next: '/v1/catalog/ng/songs?offset=25' }],
    ['upstream errors in a 200', { data: [song()], errors: [{ detail: 'secret' }] }],
  ])('rejects %s instead of mistaking a partial response for one exact match', async (_label, payload) => {
    await expect(client(async () => json(payload)).getSongsByIsrc('ng', [ISRC]))
      .rejects.toMatchObject({ category: 'response', message: 'apple_catalog:response:200' })
  })

  it.each([[401, 'authorization'], [429, 'rate_limit'], [503, 'upstream']] as const)
  ('sanitizes status %i and does not leak the Apple response', async (status, category) => {
    await expect(client(async () => json({ error: 'secret payload' }, status)).getSongsByIsrc('ng', [ISRC]))
      .rejects.toMatchObject({ category, message: `apple_catalog:${category}:${status}` })
  })
})

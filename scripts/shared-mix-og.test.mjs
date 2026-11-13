import { test } from 'node:test'
import { strict as assert } from 'node:assert'
import { createHandler } from '../netlify/edge-functions/shared-mix-og.ts'

const TOKEN = '4fQ9xK2mZr7TbW1nLpY8sA'
const API = 'https://api.example.test'
const PAGE = '<!doctype html><html><head><meta charset="UTF-8" /><title>mixtape — your personal DJ</title></head><body><div id="root"></div></body></html>'

const track = (artwork = null) => ({ title: 'Song', artist: 'Artist', album: 'Album', durationMs: 200000, artwork, appleId: '1', isrc: null })
const art = url => ({ url, width: 3000, height: 3000, bgColor: '000000' })

function mix(overrides = {}) {
  return { token: TOKEN, title: 'Late drive', caseColor: '#bc5734', sharerName: 'Ada', sharedAt: '2026-11-13T00:00:00Z', isOwner: false, tracks: [track(), track()], ...overrides }
}

function setup({ status = 200, body = mix(), fetchImpl } = {}) {
  const calls = []
  const fetch = fetchImpl ?? (async url => {
    calls.push(String(url))
    return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
  })
  const handler = createHandler({ fetch, apiBase: API, timeoutMs: 50 })
  const context = { next: async () => new Response(PAGE, { headers: { 'Content-Type': 'text/html; charset=utf-8' } }) }
  const run = async (path = `/m/${TOKEN}`) => {
    const response = await handler(new Request(`https://miixtape.netlify.app${path}`), context)
    return response.text()
  }
  return { run, calls }
}

const meta = (html, key) => {
  const match = html.match(new RegExp(`<meta (?:property|name)="${key}" content="([^"]*)"`))
  return match?.[1]
}

test('fetches the share and injects title and preview tags', async () => {
  const { run, calls } = setup({ body: mix({ tracks: [track(), track(art('https://is1.example/{w}x{h}bb.{f}')), track()] }) })
  const html = await run()
  assert.deepEqual(calls, [`${API}/shared/${TOKEN}`])
  assert.match(html, /<title>Late drive<\/title>/)
  assert.equal(html.match(/<title>/g).length, 1)
  assert.equal(meta(html, 'og:title'), 'Late drive')
  assert.equal(meta(html, 'og:description'), 'Ada shared a mix · 3 songs')
  assert.equal(meta(html, 'og:image'), 'https://is1.example/600x600bb.jpg')
  assert.equal(meta(html, 'og:url'), `https://miixtape.netlify.app/m/${TOKEN}`)
  assert.equal(meta(html, 'og:type'), 'music.playlist')
  assert.equal(meta(html, 'twitter:card'), 'summary_large_image')
  assert.ok(html.indexOf('og:title') < html.indexOf('</head>'))
})

test('escapes every value written into the page', async () => {
  const { run } = setup({ body: mix({ title: `"<b>&'x`, sharerName: '<Ada>' }) })
  const html = await run()
  assert.doesNotMatch(html, /<b>/)
  assert.match(html, /<title>&quot;&lt;b&gt;&amp;&#39;x<\/title>/)
  assert.equal(meta(html, 'og:title'), '&quot;&lt;b&gt;&amp;&#39;x')
  assert.equal(meta(html, 'og:description'), '&lt;Ada&gt; shared a mix · 2 songs')
})

test('a cleared sharer name reads "a friend", and one song is singular', async () => {
  const { run } = setup({ body: mix({ sharerName: null, tracks: [track()] }) })
  assert.equal(meta(await run(), 'og:description'), 'a friend shared a mix · 1 song')
})

test('no artwork falls back to the tape-colour card', async () => {
  const { run } = setup()
  assert.equal(meta(await run(), 'og:image'), 'https://miixtape.netlify.app/app/og/tape-bc5734.png')
})

test('an unexpected case colour falls back to the default card', async () => {
  const { run } = setup({ body: mix({ caseColor: 'url(javascript:x)' }) })
  assert.equal(meta(await run(), 'og:image'), 'https://miixtape.netlify.app/app/og/tape-3f4851.png')
})

for (const status of [404, 410]) {
  test(`${status} writes generic tags without the error`, async () => {
    const { run } = setup({ status, body: { error: status === 410 ? 'revoked' : 'not_found' } })
    const html = await run()
    assert.equal(meta(html, 'og:title'), 'A mix on Mixtape')
    assert.match(html, /<title>A mix on Mixtape<\/title>/)
    assert.doesNotMatch(html, /revoked|not_found/)
  })
}

test('other API errors leave the page unchanged', async () => {
  const { run } = setup({ status: 429, body: { error: 'rate_limited' } })
  assert.equal(await run(), PAGE)
})

test('a thrown fetch leaves the page unchanged', async () => {
  const { run } = setup({ fetchImpl: async () => { throw new Error('network down') } })
  assert.equal(await run(), PAGE)
})

test('a slow API times out and leaves the page unchanged', async () => {
  const fetchImpl = (_url, init) => new Promise((_resolve, reject) => {
    // AbortSignal.timeout's timer is unref'd in Node; hold the loop open until it fires.
    const hold = setTimeout(() => {}, 5000)
    init.signal.addEventListener('abort', () => { clearTimeout(hold); reject(init.signal.reason) })
  })
  const { run } = setup({ fetchImpl })
  assert.equal(await run(), PAGE)
})

test('a malformed body leaves the page unchanged', async () => {
  const { run } = setup({ body: { title: 42 } })
  assert.equal(await run(), PAGE)
})

for (const path of ['/m/short', `/m/${TOKEN}x`, `/m/${TOKEN.slice(0, 21)}-`, '/m/']) {
  test(`malformed token ${path} leaves the page unchanged without a fetch`, async () => {
    const { run, calls } = setup()
    assert.equal(await run(path), PAGE)
    assert.deepEqual(calls, [])
  })
}

test('a trailing slash still reads the token', async () => {
  const { run, calls } = setup()
  await run(`/m/${TOKEN}/`)
  assert.equal(calls.length, 1)
})

test('a good response is reused briefly; errors are not cached', async () => {
  let status = 500
  const calls = []
  const fetchImpl = async url => {
    calls.push(url)
    return new Response(JSON.stringify(mix()), { status })
  }
  const { run } = setup({ fetchImpl })
  await run()
  status = 200
  await run()
  await run()
  assert.equal(calls.length, 2)
})

// Link previews for shared mixes. Social crawlers don't run the app, so on /m/<token> this
// reads the public share and writes <title> plus Open Graph tags into the app's HTML.
// Any failure returns the page untouched. Declared in netlify.toml ([[edge_functions]]).

type Artwork = { url?: unknown } | null
type SharedMix = { title: string; caseColor: unknown; sharerName: string | null; tracks: { artwork?: Artwork }[] }
type Preview = { title: string; description: string; image: string; type: string }
type Context = { next: () => Promise<Response> }
type Fetch = (input: string, init: { signal: AbortSignal; headers: Record<string, string> }) => Promise<Response>

const FALLBACK_API = 'https://mixtape-api.goalympics.workers.dev'
const TOKEN_PATH = /^\/m\/([A-Za-z0-9]{22})\/?$/
const HEX = /^#([0-9a-fA-F]{6})$/
const DEFAULT_CASE = '3f4851'
const CACHE_MS = 60_000

const escape = (value: string) => value.replace(/[&<>"']/g, char => `&${{ '&': 'amp', '<': 'lt', '>': 'gt', '"': 'quot', "'": '#39' }[char]};`)

function parse(body: unknown): SharedMix | null {
  const mix = body as SharedMix
  if (!mix || typeof mix.title !== 'string' || !Array.isArray(mix.tracks)) return null
  if (mix.sharerName !== null && typeof mix.sharerName !== 'string') return null
  return mix
}

function preview(mix: SharedMix, origin: string): Preview {
  const count = mix.tracks.length
  const template = mix.tracks.map(track => track?.artwork?.url).find((url): url is string => typeof url === 'string' && url.length > 0)
  const hex = typeof mix.caseColor === 'string' ? HEX.exec(mix.caseColor)?.[1].toLowerCase() : undefined
  return {
    title: mix.title,
    description: `${mix.sharerName?.trim() || 'a friend'} shared a mix · ${count} ${count === 1 ? 'song' : 'songs'}`,
    // Apple artwork templates carry {w}x{h}.{f}.
    image: template
      ? template.replaceAll('{w}', '600').replaceAll('{h}', '600').replaceAll('{f}', 'jpg')
      : `${origin}/app/og/tape-${hex ?? DEFAULT_CASE}.png`,
    type: 'music.playlist',
  }
}

const generic = (origin: string): Preview => ({
  title: 'A mix on Mixtape',
  description: 'Mixtape is your personal DJ for the moment you are in.',
  image: `${origin}/app/og/tape-${DEFAULT_CASE}.png`,
  type: 'website',
})

function inject(html: string, tags: Preview, url: string): string {
  const head = html.indexOf('</head>')
  if (head < 0) return html
  const meta = [
    ['property', 'og:title', tags.title],
    ['property', 'og:description', tags.description],
    ['property', 'og:image', tags.image],
    ['property', 'og:url', url],
    ['property', 'og:type', tags.type],
    ['property', 'og:site_name', 'Mixtape'],
    ['name', 'twitter:card', 'summary_large_image'],
    ['name', 'twitter:title', tags.title],
    ['name', 'twitter:description', tags.description],
    ['name', 'twitter:image', tags.image],
  ].map(([attr, key, value]) => `<meta ${attr}="${key}" content="${escape(value)}" />`).join('')
  const title = `<title>${escape(tags.title)}</title>`
  const withoutTitle = html.slice(0, head).replace(/<title>[\s\S]*?<\/title>/i, '')
  return `${withoutTitle}${title}${meta}${html.slice(head)}`
}

export function createHandler({ fetch, apiBase, timeoutMs = 2500 }: { fetch: Fetch; apiBase: string; timeoutMs?: number }) {
  const cache = new Map<string, { at: number; tags: Preview }>()

  async function lookup(token: string, origin: string): Promise<Preview | null> {
    const hit = cache.get(token)
    if (hit && Date.now() - hit.at < CACHE_MS) return hit.tags
    const response = await fetch(`${apiBase.replace(/\/$/, '')}/shared/${token}`, {
      signal: AbortSignal.timeout(timeoutMs),
      headers: { Accept: 'application/json' },
    })
    // Revoked or unknown shares get a generic card; never echo the API's error.
    if (response.status === 404 || response.status === 410) return generic(origin)
    if (!response.ok) return null
    const mix = parse(await response.json())
    if (!mix) return null
    const tags = preview(mix, origin)
    cache.set(token, { at: Date.now(), tags })
    if (cache.size > 500) cache.delete(cache.keys().next().value as string)
    return tags
  }

  return async (request: Request, context: Context): Promise<Response> => {
    const url = new URL(request.url)
    const token = TOKEN_PATH.exec(url.pathname)?.[1]
    if (!token) return context.next()
    let tags: Preview | null
    try {
      tags = await lookup(token, url.origin)
    } catch {
      tags = null
    }
    const page = await context.next()
    if (!tags || !page.headers.get('content-type')?.includes('text/html')) return page
    const headers = new Headers(page.headers)
    headers.delete('content-length')
    headers.delete('etag')
    return new Response(inject(await page.text(), tags, `${url.origin}/m/${token}`), { status: page.status, headers })
  }
}

declare const Netlify: { env: { get(name: string): string | undefined } } | undefined

const env = (name: string) => {
  try {
    return typeof Netlify !== 'undefined' ? Netlify.env.get(name) : undefined
  } catch {
    return undefined
  }
}

export default createHandler({ fetch: (input, init) => fetch(input, init), apiBase: env('VITE_API_URL') || FALLBACK_API })

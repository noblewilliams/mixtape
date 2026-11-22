// Mixtape's service worker: makes the app installable and opens it offline-tolerant.
// Pages go to the network first (a deploy is seen on the next launch); hashed build
// assets are cached as they load. Nothing outside this scope, and no API or auth
// request, is ever touched. Pushes and notification taps for Mix ready
// notifications are handled at the end.
const CACHE = 'mixtape-shell-v1'
const scope = new URL(self.registration.scope)

self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE).map((key) => caches.delete(key))))
      .then(() => self.clients.claim()),
  )
})

self.addEventListener('fetch', (event) => {
  const { request } = event
  if (request.method !== 'GET') return
  const url = new URL(request.url)
  if (url.origin !== scope.origin || !url.pathname.startsWith(scope.pathname)) return

  if (request.mode === 'navigate') {
    event.respondWith(
      fetch(request)
        .then((response) => {
          if (response.ok) {
            const copy = response.clone()
            caches.open(CACHE).then((cache) => cache.put(scope.href, copy))
          }
          return response
        })
        .catch(() => caches.match(scope.href).then((cached) => cached ?? Response.error())),
    )
    return
  }

  if (url.pathname.startsWith(`${scope.pathname}assets/`)) {
    event.respondWith(
      caches.match(request).then((cached) => cached ?? fetch(request).then((response) => {
        if (response.ok) {
          const copy = response.clone()
          caches.open(CACHE).then((cache) => cache.put(request, copy))
        }
        return response
      })),
    )
  }
})

// Mix ready notifications (spec 2026-11-21 durable turns, "Web push"). The
// payload is { kind: 'ready' | 'failed', title, body, sessionId, turnId }.
// The page answers two messages (web/src/lib/web-push.ts): whether it shows a
// mix right now, and which mix to open after a tap.
const SHOWING_MIX = 'mixtape:showing-mix'
const OPEN_MIX = 'mixtape:open-mix'
const SHOWING_WAIT_MS = 500

function appWindows() {
  return self.clients
    .matchAll({ type: 'window', includeUncontrolled: true })
    .then((list) => list.filter((client) => client.url.startsWith(scope.href)))
}

// A focused window says whether that mix is on screen; no answer in time is a no.
function showsMix(client, sessionId) {
  return new Promise((resolve) => {
    const channel = new MessageChannel()
    const timer = setTimeout(() => resolve(false), SHOWING_WAIT_MS)
    channel.port1.onmessage = (event) => {
      clearTimeout(timer)
      resolve(Boolean(event.data && event.data.showing))
    }
    try {
      client.postMessage({ type: SHOWING_MIX, sessionId }, [channel.port2])
    } catch {
      clearTimeout(timer)
      resolve(false)
    }
  })
}

async function notify(payload) {
  const sessionId = typeof payload.sessionId === 'string' ? payload.sessionId : null
  if (sessionId) {
    const focused = (await appWindows()).filter((client) => client.focused)
    for (const client of focused) {
      if (await showsMix(client, sessionId)) return
    }
  }
  const options = {
    body: typeof payload.body === 'string' ? payload.body : '',
    data: { sessionId, kind: payload.kind === 'failed' ? 'failed' : 'ready' },
    icon: `${scope.href}icons/icon-192.png`,
  }
  // The turn collapses repeats of the same push.
  if (typeof payload.turnId === 'string' && payload.turnId) options.tag = payload.turnId
  await self.registration.showNotification(payload.title, options)
}

self.addEventListener('push', (event) => {
  let payload = null
  try {
    payload = event.data ? event.data.json() : null
  } catch {
    payload = null
  }
  if (!payload || typeof payload.title !== 'string' || !payload.title) return
  event.waitUntil(notify(payload))
})

async function openMix(sessionId) {
  const windows = await appWindows()
  const client = windows.find((candidate) => candidate.focused) ?? windows[0]
  if (client) {
    // A message, not a navigation: the page keeps its player and its place.
    try {
      await client.focus()
    } catch {
      // Focus can be refused; the message still opens the mix.
    }
    if (sessionId) client.postMessage({ type: OPEN_MIX, sessionId })
    return
  }
  const url = new URL(scope.href)
  if (sessionId) url.searchParams.set('mix', sessionId)
  await self.clients.openWindow(url.href)
}

self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const data = event.notification.data
  const sessionId = data && typeof data.sessionId === 'string' ? data.sessionId : null
  event.waitUntil(openMix(sessionId))
})

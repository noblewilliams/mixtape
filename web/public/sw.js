// Mixtape's service worker: makes the app installable and opens it offline-tolerant.
// Pages go to the network first (a deploy is seen on the next launch); hashed build
// assets are cached as they load. Nothing outside this scope, and no API or auth
// request, is ever touched.
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

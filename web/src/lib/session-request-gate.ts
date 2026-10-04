import type { MixtapeApi } from '../api/client'

/** Cached UI may render immediately; requests wait for a verified session. */
export function createSessionRequestGate(api: MixtapeApi) {
  let pending = 0
  const listeners = new Set<() => void>()
  const changed = () => listeners.forEach(listener => listener())
  let ready = false
  let disposed = false
  let waiting: Array<{ resolve: () => void; reject: (error: Error) => void }> = []
  const wait = () => {
    if (disposed) return Promise.reject(new DOMException('Session ended', 'AbortError'))
    if (ready) return Promise.resolve()
    return new Promise<void>((resolve, reject) => waiting.push({ resolve, reject }))
  }
  const methods = new Map<PropertyKey, unknown>()
  const gated = new Proxy(api, {
    get(target, key) {
      const method = Reflect.get(target, key)
      if (typeof method !== 'function') return method
      if (!methods.has(key)) methods.set(key, async (...args: unknown[]) => {
        const reading = /^(get|list|playbackPreferences)/.test(String(key))
        if (reading) { pending++; changed() }
        try {
          do { await wait() } while (!ready && !disposed)
          const signal = args.find(arg => arg instanceof AbortSignal) as AbortSignal | undefined
          if (signal?.aborted || disposed) throw new DOMException('Request cancelled', 'AbortError')
          return await method.apply(target, args)
        } finally {
          if (reading) { pending--; changed() }
        }
      })
      return methods.get(key)
    },
  })
  return {
    api: gated,
    getPending: () => pending,
    subscribe(listener: () => void) { listeners.add(listener); return () => { listeners.delete(listener) } },
    setReady(value: boolean) {
      disposed = false
      ready = value
      if (ready) { const pending = waiting; waiting = []; pending.forEach(request => request.resolve()) }
    },
    dispose() {
      disposed = true
      ready = false
      const pending = waiting; waiting = []
      pending.forEach(request => request.reject(new DOMException('Session ended', 'AbortError')))
    },
  }
}

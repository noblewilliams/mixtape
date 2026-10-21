import { useEffect, useState } from 'react'

function matches(query: string): boolean {
  // jsdom and older browsers may lack matchMedia; the wide layout is the default.
  return typeof window !== 'undefined' && typeof window.matchMedia === 'function'
    ? Boolean(window.matchMedia(query)?.matches)
    : false
}

export function useMediaQuery(query: string): boolean {
  const [matched, setMatched] = useState(() => matches(query))
  useEffect(() => {
    if (typeof window.matchMedia !== 'function') return
    const list = window.matchMedia(query)
    if (!list) return
    const update = () => setMatched(Boolean(list.matches))
    update()
    if (typeof list.addEventListener === 'function') {
      list.addEventListener('change', update)
      return () => list.removeEventListener('change', update)
    }
    // Safari before 14 only has the deprecated listener pair.
    if (typeof list.addListener === 'function') {
      list.addListener(update)
      return () => list.removeListener(update)
    }
  }, [query])
  return matched
}

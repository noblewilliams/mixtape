import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react'
import { isDjPaused, type MixtapeApi, type PublicConfig } from '../api/client'

/** The paused composer's placeholder. */
export const DJ_PAUSED_LINE = 'The DJ is taking a short break'
/** The one quiet line under the paused composer. */
export const DJ_PAUSED_DETAIL = "New mixes and changes are paused for now. Everything you've made still plays."
/** While paused, /health is read every minute so the composer reopens by itself. */
export const DJ_RECHECK_PAUSED_MS = 60_000
/** While open, a slow re-read catches a pause before the next send does. */
export const DJ_RECHECK_OPEN_MS = 5 * 60_000

export type DjStatus = {
  /** The DJ is paused (DJ_PAUSED): nothing that needs the model may be sent. */
  paused: boolean
  /** Hears a send's rejection: a dj_paused 503 pauses at once and answers true. */
  report: (error: unknown) => boolean
}

// Outside any provider nothing is ever paused, but a dj_paused rejection is still recognised.
const DjStatusContext = createContext<DjStatus>({ paused: false, report: isDjPaused })

/** The app's one answer to "is the DJ paused". */
export function useDjStatus(): DjStatus {
  return useContext(DjStatusContext)
}

type SourceOptions = {
  /**
   * Reads nothing on load, focus or the open clock (the first run makes no
   * request on load); only a refusal or `learn` can pause it, and once paused
   * it re-reads like the eager source until it reopens.
   */
  lazy?: boolean
}

/**
 * The source behind DjStatusProvider: GET /health on load, on focus and when
 * the tab becomes visible, every minute while paused and every five minutes
 * while open. A failed read never pauses: the last known state stays (open by
 * default). A refusal pauses at once, and a read already out cannot undo it.
 */
export function useDjStatusSource(api: Pick<MixtapeApi, 'getConfig'> | null | undefined, { lazy = false }: SourceOptions = {}) {
  const [paused, setPausedState] = useState(false)
  const pausedRef = useRef(false)
  const generation = useRef(0)
  const live = useRef(true)
  // Held in a ref: a caller passing a fresh object each render must not re-read.
  const apiRef = useRef(api)
  apiRef.current = api
  const hasApi = Boolean(api)

  const set = useCallback((next: boolean) => {
    pausedRef.current = next
    setPausedState(next)
  }, [])

  const read = useCallback(() => {
    const api = apiRef.current
    if (!api || typeof api.getConfig !== 'function') return
    const ticket = ++generation.current
    let request: Promise<PublicConfig>
    try { request = api.getConfig() } catch { return }
    request.then(
      (config) => { if (live.current && ticket === generation.current) set(config.djPaused === true) },
      () => undefined,
    )
  }, [set])

  const report = useCallback((error: unknown) => {
    if (!isDjPaused(error)) return false
    generation.current += 1
    set(true)
    return true
  }, [set])

  /** A /health answer read elsewhere (the first run's flag read). */
  const learn = useCallback((config: PublicConfig) => {
    generation.current += 1
    set(config.djPaused === true)
  }, [set])

  useEffect(() => {
    live.current = true
    if (!lazy) read()
    return () => { live.current = false }
  }, [read, lazy, hasApi])

  useEffect(() => {
    const recheck = () => { if (!lazy || pausedRef.current) read() }
    const visible = () => { if (document.visibilityState === 'visible') recheck() }
    window.addEventListener('focus', recheck)
    document.addEventListener('visibilitychange', visible)
    return () => {
      window.removeEventListener('focus', recheck)
      document.removeEventListener('visibilitychange', visible)
    }
  }, [read, lazy])

  useEffect(() => {
    if (!paused && lazy) return
    const id = setInterval(read, paused ? DJ_RECHECK_PAUSED_MS : DJ_RECHECK_OPEN_MS)
    return () => clearInterval(id)
  }, [paused, lazy, read])

  return useMemo(() => ({ paused, report, learn }), [paused, report, learn])
}

/** Provides an already-built source (the first run feeds its own flag read into it). */
export function DjStatusValue({ value, children }: { value: DjStatus; children: ReactNode }) {
  return <DjStatusContext.Provider value={value}>{children}</DjStatusContext.Provider>
}

/** Reads /health for everything under it. Use the raw api: the session gate would show "Refreshing…" on each read. */
export function DjStatusProvider({ api, lazy, children }: { api: Pick<MixtapeApi, 'getConfig'>; lazy?: boolean; children: ReactNode }) {
  const source = useDjStatusSource(api, { lazy })
  const value = useMemo<DjStatus>(() => ({ paused: source.paused, report: source.report }), [source.paused, source.report])
  return <DjStatusContext.Provider value={value}>{children}</DjStatusContext.Provider>
}

/** A fixed status, for tests and the UI preview. */
export function DjStatusFixed({ paused, children }: { paused: boolean; children: ReactNode }) {
  const value = useMemo<DjStatus>(() => ({ paused, report: isDjPaused }), [paused])
  return <DjStatusContext.Provider value={value}>{children}</DjStatusContext.Provider>
}

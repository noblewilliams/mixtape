import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import type { CreateSessionResponse, FunnelEventType } from '../../api/client'
import { createDeferredFunnel } from '../../lib/funnel-once'
import type { AuthPreferenceStore, AuthProvider } from '../../lib/auth-provider'
import { SignInPage, type AuthBridge } from '../AuthGate'
import { Artists, ARTISTS_HEADLINE } from './Artists'
import { ChooseMethod, METHOD_HEADLINE, type AddMethod } from './ChooseMethod'
import { ChooseService, SERVICE_HEADLINE, type MusicService } from './ChooseService'
import { DOING_HEADLINES, DoingPage } from './DoingPage'
import { BackButton, pageName, type FirstRunStep } from './FirstRunPage'
import { Making, MAKING_HEADLINE } from './Making'
import type { FirstRunServices } from './services'
import { Welcome, WELCOME_HEADLINE } from './Welcome'
import './first-run.css'

export type FirstRunPageId =
  | { id: 'welcome' }
  | { id: 'artists' }
  | { id: 'service' }
  | { id: 'method'; service: MusicService }
  | { id: 'doing'; method: AddMethod }
  | { id: 'prompt' }
  | { id: 'making' }
  | { id: 'sign-in' }

/** first-run: the new mix's own response, for the shell to open as it opens a new tape. */
export type FirstRunResult = { session?: CreateSessionResponse }

type SignInProps = {
  auth: Pick<AuthBridge, 'signIn'>
  preferences: AuthPreferenceStore
  lastUsed: AuthProvider | null
  error: string
  onStart?: () => void
}

export type FirstRunProps = {
  /**
   * `first-run`: Welcome, the artists page, path B and the prompt page, ending
   * with the first mix. `add`: path B alone (Library's Add your music),
   * ending back where it was opened.
   */
  mode?: 'first-run' | 'add'
  /** The runs and API; a factory is called once, on the first render. */
  services?: FirstRunServices | (() => FirstRunServices)
  /** The sign-in page behind the welcome foot link (first-run mode). */
  signIn?: SignInProps
  /** A Step 1 choice, for the caller's own record of it. */
  onChooseService?: (service: MusicService) => void
  /** first-run: the new mix. add: finished or left. */
  onDone: (result: FirstRunResult) => void
}

const HISTORY_KEY = 'mixtapeFirstRun'
const MIX_FAILED = 'Couldn’t make your mix. Try again.'
const SAVE_FAILED = 'Couldn’t save your artists. Try again.'
/** How long Skip for now waits on a flag read still in flight; past it, off. */
export const SKIP_CONFIG_WAIT_MS = 1000

type Marker = { flow: string; step: number }

function marker(state: unknown): Marker | null {
  if (!state || typeof state !== 'object') return null
  const value = (state as Record<string, unknown>)[HISTORY_KEY]
  return value && typeof value === 'object' ? (value as Marker) : null
}

function withMarker(flow: string, step: number) {
  const current = window.history.state
  return { ...(current && typeof current === 'object' ? current : {}), [HISTORY_KEY]: { flow, step } }
}

function headlineOf(page: FirstRunPageId): { headline: string; step?: FirstRunStep } {
  switch (page.id) {
    case 'welcome':
    case 'prompt':
      return { headline: WELCOME_HEADLINE }
    case 'artists':
      return { headline: ARTISTS_HEADLINE }
    case 'service':
      return { headline: SERVICE_HEADLINE, step: 1 }
    case 'method':
      return { headline: METHOD_HEADLINE, step: 2 }
    case 'doing':
      return { headline: DOING_HEADLINES[page.method], step: 3 }
    case 'making':
      return { headline: MAKING_HEADLINE }
    case 'sign-in':
      return { headline: 'Your music, mixed for right now.' }
  }
}

/**
 * The first-run flow. Every page is a history entry, so the browser's back
 * answers the outlined back button; the document title and the focused
 * heading carry the page name. Nothing reaches the server until a page sends
 * the first prompt, saves artists, starts a sync, or records a request, and
 * each of those calls ensureSession() first.
 */
export function FirstRun({ mode = 'first-run', services: provided, signIn, onChooseService, onDone }: FirstRunProps) {
  const adding = mode === 'add'
  const [flow] = useState(() => Math.random().toString(36).slice(2))
  const [services] = useState<FirstRunServices | null>(() =>
    typeof provided === 'function' ? provided() : provided ?? null,
  )
  const initial: FirstRunPageId[] = adding
    ? [{ id: 'service' }]
    : signIn?.error
      ? [{ id: 'welcome' }, { id: 'sign-in' }]
      : [{ id: 'welcome' }]
  // The visited trail survives a back so the browser's forward can return.
  const trail = useRef<FirstRunPageId[]>(initial)
  const [depth, setDepthState] = useState(initial.length - 1)
  // The live depth, for a mix request that settles after later navigation.
  const depthRef = useRef(initial.length - 1)
  const setDepth = useCallback((next: number) => {
    depthRef.current = next
    setDepthState(next)
  }, [])
  // The first mix in flight (a DJ turn of up to a minute), and the error the
  // pop off the making page should show on the page it lands on.
  const mixing = useRef(false)
  const popError = useRef('')
  const navigated = useRef(false)
  const finished = useRef(false)
  const [prompt, setPrompt] = useState('')
  const [pendingPrompt, setPendingPrompt] = useState<string | null>(null)
  const [artists, setArtists] = useState<string[]>([])
  const [seedsSaved, setSeedsSaved] = useState(false)
  const [songsIn, setSongsIn] = useState<number | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [syncStartFailed, setSyncStartFailed] = useState(false)
  const page = trail.current[depth] ?? trail.current[0]

  // The first run's funnel (not Library's add flow). Events wait in memory
  // until the first server action has made sure of the session.
  const [funnel] = useState(() => (!adding && services ? createDeferredFunnel(services.api) : null))
  const record = (type: FunnelEventType) => funnel?.record(type)
  useEffect(() => {
    funnel?.record('first_run_opened')
  }, [funnel])
  // NEVER_REFUSE, read once per flow from the public /health (no session is
  // made for it). The read starts when Step 1 opens, the only page whose Skip
  // for now it steers, so the first run still makes no request on load.
  // Until it lands, or if it fails, it is off: Skip goes to the artists page.
  const [neverRefuse, setNeverRefuse] = useState(false)
  const configRead = useRef<Promise<boolean> | null>(null)
  const onStep1 = page.id === 'service'
  useEffect(() => {
    if (adding || !services || !onStep1) return
    configRead.current ??= services.api.getConfig().then(
      (config) => config.neverRefuse,
      () => false,
    )
    let live = true
    void configRead.current.then((on) => {
      if (live) setNeverRefuse(on)
    })
    return () => {
      live = false
    }
  }, [adding, services, onStep1])
  const ensure = useCallback(async () => {
    if (!services) return
    await services.ensureSession()
    funnel?.flush()
  }, [services, funnel])
  // The doing page's own server actions (import, request) flush the funnel too.
  const flowServices = useMemo(() => (services ? { ...services, ensureSession: ensure } : null), [services, ensure])

  const exit = useCallback(
    (result: FirstRunResult) => {
      if (finished.current) return
      finished.current = true
      onDone(result)
    },
    [onDone],
  )

  // History: the first page owns (first-run) or adds (add) an entry; each
  // later page pushes one. Guarded so StrictMode's second effect run does
  // not write twice.
  const historyReady = useRef(false)
  useEffect(() => {
    if (!historyReady.current) {
      historyReady.current = true
      if (adding) window.history.pushState(withMarker(flow, 0), '')
      else window.history.replaceState(withMarker(flow, 0), '')
      for (let step = 1; step < trail.current.length; step += 1) window.history.pushState(withMarker(flow, step), '')
    }
    const onPop = (event: PopStateEvent) => {
      if (finished.current) return
      const mark = marker(event.state)
      navigated.current = true
      setError(popError.current)
      popError.current = ''
      if (mark?.flow === flow) {
        const step = Math.min(mark.step, trail.current.length - 1)
        // Forward onto a making page whose request already settled: step back off it.
        if (trail.current[step]?.id === 'making' && !mixing.current) {
          window.history.back()
          return
        }
        setDepth(step)
      } else if (adding) exit({})
      else setDepth(0)
    }
    window.addEventListener('popstate', onPop)
    return () => window.removeEventListener('popstate', onPop)
  }, [adding, exit, flow, setDepth])

  const { headline, step } = headlineOf(page)
  useEffect(() => {
    const before = document.title
    document.title = pageName(headline, step)
    return () => {
      document.title = before
    }
  }, [headline, step])

  useEffect(() => {
    if (page.id !== 'sign-in' || !navigated.current) return
    document.getElementById('auth-title')?.focus({ preventScroll: true })
  }, [page.id, depth])

  function push(next: FirstRunPageId) {
    const at = depthRef.current
    trail.current = [...trail.current.slice(0, at + 1), next]
    navigated.current = true
    setError('')
    setDepth(at + 1)
    window.history.pushState(withMarker(flow, at + 1), '')
  }

  const back = () => window.history.back()

  /** Leave for the shell or the Library, folding the flow's entries back first. */
  function finish(result: FirstRunResult) {
    const at = depthRef.current
    const entries = adding ? at + 1 : at
    exit(result)
    // The pop lands after exit, which already stopped this flow listening.
    if (entries > 0) window.history.go(-entries)
  }

  /**
   * The first mix: push the making page the moment the request starts. It
   * keeps running through a browser back; success hands off from wherever the
   * listener is, and failure pops off the making page (or shows on the
   * current page) with the prompt and artists kept.
   */
  async function makeMix(text: string, ensured = false) {
    if (!services) return setError(MIX_FAILED)
    // A request is already running (the listener went back and pressed again): show it.
    if (mixing.current) return push({ id: 'making' })
    mixing.current = true
    push({ id: 'making' })
    try {
      if (!ensured) await ensure()
      const response = await services.api.createSession(text)
      mixing.current = false
      finish({ session: response })
    } catch {
      mixing.current = false
      if (trail.current[depthRef.current]?.id === 'making') {
        popError.current = MIX_FAILED
        window.history.back()
      } else setError(MIX_FAILED)
    }
  }

  /**
   * Path A: with nothing synced in this flow, the artists page comes first,
   * except on the prompt page Skip for now opened with never refuse on.
   */
  function send(text: string) {
    if (page.id === 'welcome') record('chose_make_mix')
    // neverRefuse on the prompt page: only Skip for now's route lands there without seeds or songs today.
    if (seedsSaved || (songsIn ?? 0) > 0 || (neverRefuse && page.id === 'prompt')) void makeMix(text)
    else {
      setPendingPrompt(text)
      push({ id: 'artists' })
    }
  }

  async function saveArtists(names: string[]) {
    setArtists(names)
    if (!services) return setError(SAVE_FAILED)
    setBusy(true)
    setError('')
    try {
      await ensure()
      await services.api.putArtistSeeds(names)
      setSeedsSaved(true)
    } catch {
      setError(SAVE_FAILED)
      setBusy(false)
      return
    }
    setBusy(false)
    if (pendingPrompt) void makeMix(pendingPrompt, true)
    else push({ id: 'prompt' })
  }

  /**
   * Step 1's Skip for now: the prompt page with never refuse on, else the
   * artists page. Waits on the flag read if it is still in flight, at most
   * SKIP_CONFIG_WAIT_MS (then off); a second tap while waiting is ignored,
   * and a back during the wait wins.
   */
  const skipping = useRef(false)
  async function skip() {
    if (adding) return finish({})
    if (skipping.current) return
    skipping.current = true
    const at = depthRef.current
    let timer: ReturnType<typeof setTimeout> | undefined
    const capped = new Promise<boolean>((resolve) => {
      timer = setTimeout(() => resolve(false), SKIP_CONFIG_WAIT_MS)
    })
    const on = await Promise.race([configRead.current ?? Promise.resolve(false), capped])
    clearTimeout(timer)
    skipping.current = false
    if (finished.current || depthRef.current !== at || trail.current[at]?.id !== 'service') return
    push(on ? { id: 'prompt' } : { id: 'artists' })
  }

  function startSync() {
    if (!services) return
    setSyncStartFailed(false)
    ensure().then(
      () => services.syncRun.start(),
      () => setSyncStartFailed(true),
    )
  }

  function chooseMethod(method: AddMethod) {
    record('chose_method')
    push({ id: 'doing', method })
    if (method === 'apple-sync') startSync()
  }

  /** After the doing page: the prompt page, or the artists page first when nothing usable came in. */
  function added(songs: number) {
    record('sync_done')
    if (adding) return finish({})
    setSongsIn(songs)
    push(songs > 0 || seedsSaved ? { id: 'prompt' } : { id: 'artists' })
  }

  // Library's add flow opens over the shell, so its first page takes focus too.
  const focusHeading = navigated.current || adding
  const key = `${depth}-${page.id}`
  let content
  switch (page.id) {
    case 'welcome':
    case 'prompt':
      content = (
        <Welcome
          key={key}
          draft={prompt}
          onDraft={setPrompt}
          onSend={send}
          onAddMusic={page.id === 'welcome' ? () => { record('chose_add_music'); setPendingPrompt(null); push({ id: 'service' }) } : undefined}
          line={page.id === 'prompt' && songsIn ? `${songsIn.toLocaleString()} songs in. Ask for anything.` : undefined}
          onSignIn={() => push({ id: 'sign-in' })}
          onBack={page.id === 'prompt' ? back : undefined}
          busy={busy}
          error={error}
          focusHeading={focusHeading}
        />
      )
      break
    case 'artists':
      content = (
        <Artists key={key} initial={artists} onContinue={(names) => void saveArtists(names)} onBack={back} busy={busy} error={error} focusHeading={focusHeading} />
      )
      break
    case 'service':
      content = (
        <ChooseService
          key={key}
          onChoose={(service) => {
            record('chose_service')
            onChooseService?.(service)
            push({ id: 'method', service })
          }}
          onSkip={() => void skip()}
          onBack={back}
          focusHeading={focusHeading}
        />
      )
      break
    case 'method':
      content = <ChooseMethod key={key} service={page.service} onChoose={chooseMethod} onBack={back} focusHeading={focusHeading} />
      break
    case 'doing':
      content = flowServices ? (
        <DoingPage
          key={key}
          method={page.method}
          services={flowServices}
          onBack={back}
          focusHeading={focusHeading}
          onStartSync={startSync}
          syncStartFailed={syncStartFailed}
          onSynced={added}
          onImported={added}
          onRequested={() => (adding ? finish({}) : push(seedsSaved ? { id: 'prompt' } : { id: 'artists' }))}
          importDoneLabel={adding ? 'Done' : undefined}
        />
      ) : null
      break
    case 'making':
      content = <Making key={key} focusHeading={focusHeading} />
      break
    case 'sign-in':
      content = signIn ? (
        <div className="fr-sign-in" key={key}>
          <BackButton onBack={back} className="fr-back--over" />
          <SignInPage {...signIn} />
        </div>
      ) : null
      break
  }

  return (
    <div className={`first-run fr-root${adding ? ' fr-root--add' : ''}`} data-testid="first-run">
      <div className="fr-stage" key={key}>{content}</div>
    </div>
  )
}

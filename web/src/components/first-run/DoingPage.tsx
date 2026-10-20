import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react'
import type { MusicSyncRun, MusicSyncRunState } from '../../sync/music-sync-run'
import { Cassette } from '../Cassette'
import { ErrorCircleIcon, SyncIcon } from '../Icons'
import { ImportPanel, type ImportPanelHandle } from '../ImportPanel'
import { ExportifySteps, MARK_FAILED, SpotifyRequestSteps } from '../SpotifyMusicView'
import type { AddMethod } from './ChooseMethod'
import { FirstRunPage, Pill } from './FirstRunPage'
import { importRunWithSession, type FirstRunServices } from './services'

export const DOING_HEADLINES: Record<AddMethod, string> = {
  'apple-sync': 'Syncing your library',
  exportify: 'Export from Exportify',
  'spotify-export': 'Request your data',
}
const EXPORTIFY_URL = 'https://exportify.app/'
const SONG_STAGES = new Set(['library_songs', 'uploading_library'])
const ANNOUNCE_EVERY_MS = 10_000

type Props = {
  method: AddMethod
  services: FirstRunServices
  onBack: () => void
  focusHeading?: boolean
  /** Starts (or restarts) the sync with the session made sure of; the Step 2 click runs it first. */
  onStartSync: () => void
  /** The sync could not even start (no session could be created). */
  syncStartFailed?: boolean
  /** Apple: Done or Continue with what’s in, with the songs counted. */
  onSynced: (songs: number) => void
  /** Exportify: the import's own finish button, with the songs it brought. */
  onImported: (songs: number) => void
  /** Spotify data export: I’ve requested it, once recorded. */
  onRequested: () => void
  /** The import panel's finish label; the first run continues to the prompt. */
  importDoneLabel?: string
}

/** Step 3 of 3: the existing sync run, import panel or request steps inside the step chrome. */
export function DoingPage(props: Props) {
  const { method, onBack, focusHeading } = props
  return (
    <FirstRunPage
      background="step-3"
      step={3}
      headline={DOING_HEADLINES[method]}
      onBack={onBack}
      focusHeading={focusHeading}
      before={method === 'apple-sync' ? <SyncHero run={props.services.syncRun} failed={props.syncStartFailed} /> : undefined}
    >
      {method === 'apple-sync' ? <AppleSync {...props} /> : method === 'exportify' ? <Exportify {...props} /> : <SpotifyRequest {...props} />}
    </FirstRunPage>
  )
}

type SyncPhase = 'working' | 'done' | 'failed'

function syncPhase(state: MusicSyncRunState, startFailed: boolean): SyncPhase {
  if (state.kind === 'running' || state.kind === 'cancelling') return 'working'
  if (state.kind === 'result') return state.result.kind === 'complete' ? 'done' : 'failed'
  if (state.kind === 'idle') return startFailed ? 'failed' : 'working'
  return 'failed'
}

function SyncHero({ run, failed = false }: { run: MusicSyncRun; failed?: boolean }) {
  const state = useSyncExternalStore(run.subscribe, run.getState)
  return (
    <div className="fr-hero" aria-hidden="true">
      <Cassette className="fr-cassette" loading={syncPhase(state, failed) === 'working'} labelled={false} />
    </div>
  )
}

function songsOf(state: MusicSyncRunState): number | null {
  if ((state.kind === 'running' || state.kind === 'cancelling') && state.progress && SONG_STAGES.has(state.progress.stage)) {
    return state.progress.completed
  }
  if (state.kind === 'result') {
    return state.result.kind === 'complete' ? state.result.songs : state.result.library?.songs ?? null
  }
  return null
}

function AppleSync({ services, onStartSync, syncStartFailed = false, onSynced }: Props) {
  const run = services.syncRun
  const state = useSyncExternalStore(run.subscribe, run.getState)
  const phase = syncPhase(state, syncStartFailed)
  // The count only grows within a visit: reading and uploading each count from
  // zero, and a failure keeps what came in.
  const [songs, setSongs] = useState(0)
  useEffect(() => {
    const seen = songsOf(state)
    if (seen !== null) setSongs((current) => (state.kind === 'result' ? seen : Math.max(current, seen)))
  }, [state])
  const line =
    phase === 'done'
      ? `${songs.toLocaleString()} songs in.`
      : phase === 'failed'
        ? `Sync stopped at ${songs.toLocaleString()} songs.`
        : songs > 0
          ? `${songs.toLocaleString()} songs so far`
          : ''
  // A polite live region, announced at most once every ten seconds while the
  // sync runs; the end is announced at once, a failure as an alert.
  const [announced, setAnnounced] = useState('')
  const lastAnnounce = useRef(0)
  useEffect(() => {
    if (phase === 'done') setAnnounced(line)
    else if (phase === 'working' && line) {
      const now = Date.now()
      if (now - lastAnnounce.current >= ANNOUNCE_EVERY_MS) {
        lastAnnounce.current = now
        setAnnounced(line)
      }
    }
  }, [phase, line])
  function retry() {
    if (state.kind === 'result' && state.result.kind === 'unconfirmed') run.check()
    else onStartSync()
  }
  return (
    <>
      {phase === 'failed' ? (
        <p className="fr-status fr-status--err" role="alert"><ErrorCircleIcon className="fr-status-icon" />{line}</p>
      ) : (
        <p className="fr-status" aria-hidden="true">{line || ' '}</p>
      )}
      <p className="sr-only" role="status">{phase === 'failed' ? '' : announced}</p>
      <div className="fr-acts">
        {phase === 'failed' ? (
          <>
            <Pill onClick={retry}><SyncIcon className="fr-pill-icon" />Retry</Pill>
            <Pill go onClick={() => onSynced(songs)}>Continue with what’s in</Pill>
          </>
        ) : (
          <>
            <span className="fr-pill fr-pill--ghost" aria-hidden="true">Retry</span>
            <Pill go disabled={phase !== 'done'} onClick={() => onSynced(songs)}>Done</Pill>
          </>
        )}
      </div>
    </>
  )
}

function Exportify({ services, onImported, importDoneLabel }: Props) {
  const [sessionError, setSessionError] = useState(false)
  const run = useMemo(
    () => importRunWithSession(services.importRun, services.ensureSession, () => setSessionError(true)),
    [services],
  )
  const picking = useSyncExternalStore(run.subscribe, () => run.getState().kind === 'pick')
  const panel = useRef<ImportPanelHandle>(null)
  // B6: the pick step is a pill, so the whole page takes a dropped export.
  useEffect(() => {
    if (!picking) return
    const over = (event: DragEvent) => event.preventDefault()
    const drop = (event: DragEvent) => {
      event.preventDefault()
      const files = Array.from(event.dataTransfer?.files ?? [])
      if (files.length) panel.current?.takeFiles(files)
    }
    window.addEventListener('dragover', over)
    window.addEventListener('drop', drop)
    return () => {
      window.removeEventListener('dragover', over)
      window.removeEventListener('drop', drop)
    }
  }, [picking])
  function finish() {
    const state = run.getState()
    const summary = state.kind === 'done' || state.kind === 'partial' ? state.result.summary : null
    onImported(summary ? summary.libraryTracks || summary.tracks : 0)
  }
  const importPanel = (
    <ImportPanel ref={panel} run={run} onNewTape={finish} mixLabel={importDoneLabel} pickVariant="pill" />
  )
  return (
    <>
      <div className="fr-steps"><ExportifySteps /></div>
      {sessionError ? <p className="fr-status fr-status--err" role="alert">{MARK_FAILED}</p> : null}
      <div className="fr-acts">
        <a className="fr-pill" href={EXPORTIFY_URL} target="_blank" rel="noopener noreferrer" aria-label="Open Exportify (opens outside Mixtape)">
          Open Exportify
          <svg className="fr-glyph fr-ext" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M14 4h6v6M20 4l-9 9M18 14v4.5a1.5 1.5 0 0 1-1.5 1.5h-11A1.5 1.5 0 0 1 4 18.5v-11A1.5 1.5 0 0 1 5.5 6H10" />
          </svg>
        </a>
        {picking ? importPanel : null}
      </div>
      {/* The review and upload keep the Library's look, on paper. */}
      {picking ? null : <div className="fr-host">{importPanel}</div>}
    </>
  )
}

function SpotifyRequest({ services, onRequested }: Props) {
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  async function mark() {
    setSaving(true)
    setError('')
    try {
      await services.ensureSession()
      await services.api.postFunnelEvent({ type: 'marked_requested', surface: 'web' })
      onRequested()
    } catch {
      setError(MARK_FAILED)
      setSaving(false)
    }
  }
  return (
    <>
      <div className="fr-steps fr-steps--dense"><SpotifyRequestSteps /></div>
      {error ? <p className="fr-status fr-status--err" role="alert">{error}</p> : null}
      <div className="fr-acts">
        <Pill go disabled={saving} onClick={() => void mark()}>I’ve requested it</Pill>
      </div>
    </>
  )
}

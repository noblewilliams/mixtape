// The import page: pick or drop a ZIP, read it on this device, show exactly
// what will leave it, upload with live progress, then the summary. Owns the
// one-run gate (busy while an upload is in flight) and the parser's lifetime:
// a Worker exists only between the first read of a file and cancel or finish.
// Nothing here logs: the snapshot carries track, artist, and playlist names.

import {
  Fragment,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
  type ChangeEvent,
  type DragEvent,
  type Ref,
} from 'react'
import { formatBytes, formatCount, formatDiagnosticsReport } from '../import/diagnostics-report'
import {
  LISTENING_ARTIST_CHUNK,
  LISTENING_DAY_CHUNK,
  LISTENING_LIBRARY_CHUNK,
  LISTENING_TRACK_CHUNK,
  type ListeningImportProgress,
  type ListeningImportResult,
  type ListeningImportService,
} from '../import/import-service'
import type { PageParser } from '../import/page-parser'
import type { ExportInventory, ListeningExportPackage, ListeningExportSnapshot } from '../import/snapshot'
import { ledgerRangeLabel } from '../lib/onboarding'

export type ImportPanelHandle = {
  /** Back to the drop zone (when no upload is running) and focus it. */
  focus(): void
}

type ImportPanelProps = {
  importService: ListeningImportService
  parser: PageParser
  onRefresh: () => Promise<void>
  onNewTape: () => void
  onBusyChange?: (busy: boolean) => void
  ref?: Ref<ImportPanelHandle>
}

/** What the inventory shows: the listing plus the counts a first parse gives. */
type Facts = {
  package: ListeningExportPackage
  inventory: ExportInventory
  timeZone: string
  tracks: number
  days: number
  library: number
  artists: number
  playlists: number
  unresolvedRows: number
  ledgerFrom: string | null
  ledgerTo: string | null
}

type PanelState =
  | { kind: 'pick' }
  | { kind: 'inspecting'; file: File; progress: ListeningImportProgress | null }
  | { kind: 'inventory'; file: File; facts: Facts }
  | { kind: 'uploading'; file: File; facts: Facts; progress: ListeningImportProgress | null; percent: number }
  | { kind: 'done'; file: File; facts: Facts; result: ListeningImportResult }
  | { kind: 'partial'; file: File; facts: Facts; result: ListeningImportResult }
  | { kind: 'upload-failed'; file: File; facts: Facts }
  | {
      kind: 'unreadable'
      file: File
      /** False when the file could not even be opened as a ZIP. */
      zip: boolean
      brokenFile: string | null
      report: string | null
    }

const EXPECTED_FILES = 'Expected files: Streaming_History_Audio_*.json, YourLibrary.json, Playlist*.json.'
const COPY_UNAVAILABLE = 'Copy isn’t available here. Select the report and copy it by hand.'
const NOTHING_OPEN = 'nothing needs to stay open in Spotify'

const baseName = (path: string): string => path.slice(path.lastIndexOf('/') + 1)

function deviceTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
  } catch {
    return 'UTC'
  }
}

function factsFrom(inventory: ExportInventory, snapshot: ListeningExportSnapshot, timeZone: string): Facts {
  return {
    package: snapshot.package,
    inventory,
    timeZone,
    tracks: snapshot.tracks.length,
    days: snapshot.days.length,
    library: snapshot.library.length,
    artists: snapshot.artists.length,
    playlists: snapshot.playlists.length,
    unresolvedRows: snapshot.unresolved.rows,
    ledgerFrom: snapshot.ledgerFrom,
    ledgerTo: snapshot.ledgerTo,
  }
}

type Unreadable = { file: string | null; inventory: ExportInventory }

/** The parser's fail-closed error, whether raised in-page or revived from the Worker. */
function asUnreadable(error: unknown): Unreadable | null {
  if (typeof error !== 'object' || error === null) return null
  const candidate = error as { name?: unknown; file?: unknown; inventory?: unknown }
  if (candidate.name !== 'UnreadableExportError' || typeof candidate.inventory !== 'object' || !candidate.inventory) {
    return null
  }
  return {
    file: typeof candidate.file === 'string' ? candidate.file : null,
    inventory: candidate.inventory as ExportInventory,
  }
}

function yearsLabel(from: string | null, to: string | null): string | null {
  if (!from) return null
  const start = from.slice(0, 4)
  const end = (to ?? from).slice(0, 4)
  return start === end ? start : `${start} – ${end}`
}

function packageLabel(pkg: ListeningExportPackage): string {
  return pkg === 'spotify_extended' ? 'Extended streaming history' : 'Account data'
}

function plural(count: number, noun: string): string {
  return `${formatCount(count)} ${noun}${count === 1 ? '' : 's'}`
}

const unresolvedLabel = (rows: number): string => (rows === 0 ? 'None' : plural(rows, 'row'))

const ledgerLabel = (summary: ListeningImportResult['summary']): string =>
  ledgerRangeLabel(summary.ledgerFrom, summary.ledgerTo) ?? '—'

type ParseStep = Extract<ListeningImportProgress, { file: string | null }>

function isParseProgress(progress: ListeningImportProgress): progress is ParseStep {
  return 'file' in progress
}

// Bands per stage so the bar only ever moves forward; within a band the
// fraction is the rows (or files) actually done. Upload stages absent from a
// package emit nothing and are skipped by the next band.
const UPLOAD_BANDS: Record<string, [start: number, span: number]> = {
  uploading_tracks: [20, 20],
  uploading_days: [40, 30],
  uploading_library: [70, 10],
  uploading_artists: [80, 5],
  uploading_playlists: [85, 15],
}

function percentFor(progress: ListeningImportProgress): number {
  const fraction = progress.total > 0 ? Math.min(1, progress.completed / progress.total) : 1
  if (isParseProgress(progress)) {
    if (progress.stage === 'listing') return 0
    if (progress.stage === 'reading') return Math.round(20 * fraction)
    return 20
  }
  if (progress.stage === 'complete') return 100
  const [start, span] = UPLOAD_BANDS[progress.stage] ?? [20, 0]
  return Math.round(start + span * fraction)
}

const UPLOAD_NOUNS: Record<string, [noun: string, chunk: number]> = {
  uploading_tracks: ['tracks', LISTENING_TRACK_CHUNK],
  uploading_days: ['days', LISTENING_DAY_CHUNK],
  uploading_library: ['liked songs', LISTENING_LIBRARY_CHUNK],
  uploading_artists: ['artists', LISTENING_ARTIST_CHUNK],
}

/** The stage line under the band, and the shorter form the chip announces. */
function stageLabel(progress: ListeningImportProgress | null): { line: string; announce: string } {
  if (progress === null) return { line: 'Reading the archive', announce: 'reading' }
  if (isParseProgress(progress)) {
    if (progress.stage === 'listing') return { line: 'Reading the archive', announce: 'reading' }
    if (progress.stage === 'reading') {
      const part = `files ${progress.completed} of ${progress.total}`
      return { line: `Reading ${part}`, announce: part }
    }
    return { line: `Read ${plural(progress.total, 'file')}, starting the upload`, announce: 'starting the upload' }
  }
  if (progress.stage === 'complete') return { line: 'Finishing', announce: 'finishing' }
  if (progress.stage === 'uploading_playlists') {
    const part = `playlists ${formatCount(progress.completed)} of ${formatCount(progress.total)}`
    return { line: `Uploading ${part}`, announce: part }
  }
  const [noun, chunk] = UPLOAD_NOUNS[progress.stage] ?? ['rows', 1]
  const done = Math.max(1, Math.ceil(progress.completed / chunk))
  const chunks = Math.max(1, Math.ceil(progress.total / chunk))
  const part = `${noun} ${done} of ${chunks}`
  return { line: `Uploading ${part}`, announce: part }
}

function unreadableCopy(state: Extract<PanelState, { kind: 'unreadable' }>): string {
  if (!state.zip) {
    return (
      'This file couldn’t be opened as a ZIP, so nothing was uploaded. ' +
      `Give Mixtape the ZIP Spotify emailed, unchanged. ${EXPECTED_FILES}`
    )
  }
  if (state.brokenFile === null) {
    return `This ZIP holds none of the Spotify export files, so nothing was uploaded. ${EXPECTED_FILES}`
  }
  const which = /^streaming_history_audio_/i.test(state.brokenFile) ? 'One of the history files' : 'One of the files'
  return `${which} couldn’t be read, so nothing was uploaded. ${EXPECTED_FILES}`
}

type ChipTone = 'ok' | 'wait' | 'err'

function Chip({ tone, label, announce }: { tone: ChipTone; label: string; announce?: string }) {
  return (
    <span className={`status-chip ${tone}`} role="status">
      <span className="dot" aria-hidden="true" />
      {label}
      {announce ? <span className="sr-only">, {announce}</span> : null}
    </span>
  )
}

function Definitions({ rows }: { rows: [term: string, definition: string][] }) {
  return (
    <dl>
      {rows.map(([term, definition]) => (
        <Fragment key={term}>
          <dt>{term}</dt>
          <dd>{definition}</dd>
        </Fragment>
      ))}
    </dl>
  )
}

function FileList({ inventory }: { inventory: ExportInventory }) {
  return (
    <ul className="file-list">
      {inventory.read.map((file) => (
        <li key={file.path}>
          <span className="file-name">{baseName(file.path)}</span>
        </li>
      ))}
      {inventory.ignored.map((file) => (
        <li key={file.path} className="ignored">
          <span className="file-name">{baseName(file.path)}</span> <span className="file-label">ignored</span>
        </li>
      ))}
    </ul>
  )
}

function inventoryRows(facts: Facts): [string, string][] {
  const skipped = facts.unresolvedRows === 0 ? 'None' : formatCount(facts.unresolvedRows)
  if (facts.package === 'spotify_extended') {
    return [
      ['Tracks', formatCount(facts.tracks)],
      ['Days with plays', formatCount(facts.days)],
      ['Years', yearsLabel(facts.ledgerFrom, facts.ledgerTo) ?? '—'],
      ['Local days in', facts.timeZone],
      ['Skipped rows', skipped],
    ]
  }
  return [
    ['Tracks', formatCount(facts.tracks)],
    ['Liked songs', formatCount(facts.library)],
    ['Artists', formatCount(facts.artists)],
    ['Playlists', formatCount(facts.playlists)],
    ['Skipped rows', skipped],
  ]
}

export function ImportPanel({ importService, parser, onRefresh, onNewTape, onBusyChange, ref }: ImportPanelProps) {
  const [state, setState] = useState<PanelState>({ kind: 'pick' })
  const [includePrivate, setIncludePrivate] = useState(false)
  const [dragOver, setDragOver] = useState(false)
  const [copyStatus, setCopyStatus] = useState('')
  const rootRef = useRef<HTMLElement>(null)
  const controllerRef = useRef<AbortController | null>(null)
  // Bumped whenever a run is superseded (cancel, reset, unmount) so a late
  // rejection from the old run never writes over the new state.
  const runRef = useRef(0)
  const pendingFocus = useRef(false)
  const parserRef = useRef(parser)
  parserRef.current = parser
  const onBusyChangeRef = useRef(onBusyChange)
  onBusyChangeRef.current = onBusyChange

  const busy = state.kind === 'uploading'
  useEffect(() => {
    onBusyChangeRef.current?.(busy)
  }, [busy])

  useEffect(
    () => () => {
      runRef.current += 1
      controllerRef.current?.abort()
      parserRef.current.terminate()
      onBusyChangeRef.current?.(false)
    },
    [],
  )

  useEffect(() => {
    if (state.kind !== 'pick' || !pendingFocus.current) return
    pendingFocus.current = false
    rootRef.current?.scrollIntoView?.({ block: 'center' })
    rootRef.current?.focus()
  }, [state.kind])

  function supersede(): number {
    runRef.current += 1
    controllerRef.current?.abort()
    controllerRef.current = null
    return runRef.current
  }

  function reset() {
    supersede()
    parserRef.current.terminate()
    setCopyStatus('')
    setIncludePrivate(false)
    setState({ kind: 'pick' })
  }

  useImperativeHandle(
    ref,
    () => ({
      focus() {
        if (state.kind === 'uploading' || state.kind === 'inspecting') {
          rootRef.current?.scrollIntoView?.({ block: 'center' })
          return
        }
        pendingFocus.current = true
        if (state.kind === 'pick') {
          pendingFocus.current = false
          rootRef.current?.scrollIntoView?.({ block: 'center' })
          rootRef.current?.focus()
          return
        }
        reset()
      },
    }),
    [state.kind],
  )

  async function fail(run: number, file: File, error: unknown, signal: AbortSignal) {
    const unreadable = asUnreadable(error)
    let report: string | null = null
    try {
      const diagnostics = await parserRef.current.diagnose(file, { signal })
      report = formatDiagnosticsReport(diagnostics, unreadable?.inventory ?? null)
    } catch {
      report = null
    }
    if (run !== runRef.current) return
    parserRef.current.terminate()
    setState({
      kind: 'unreadable',
      file,
      zip: unreadable !== null || report !== null,
      brokenFile: unreadable?.file ?? null,
      report,
    })
  }

  async function take(file: File) {
    const run = supersede()
    const controller = new AbortController()
    controllerRef.current = controller
    setCopyStatus('')
    setIncludePrivate(false)
    setState({ kind: 'inspecting', file, progress: null })
    try {
      const inventory = await importService.inspect(file, { signal: controller.signal })
      const timeZone = deviceTimeZone()
      const { snapshot } = await parserRef.current.parse(file, {
        timeZone,
        includePrivateSessions: false,
        signal: controller.signal,
        onProgress: (progress) => {
          setState((current) =>
            current.kind === 'inspecting' && run === runRef.current ? { ...current, progress } : current,
          )
        },
      })
      if (run !== runRef.current) return
      setState({ kind: 'inventory', file, facts: factsFrom(inventory, snapshot, timeZone) })
    } catch (error) {
      if (run !== runRef.current || controller.signal.aborted) return
      await fail(run, file, error, controller.signal)
    } finally {
      if (controllerRef.current === controller) controllerRef.current = null
    }
  }

  async function upload() {
    if (state.kind !== 'inventory') return
    const { file, facts } = state
    const run = supersede()
    const controller = new AbortController()
    controllerRef.current = controller
    let percent = 0
    setState({ kind: 'uploading', file, facts, progress: null, percent })
    try {
      const result = await importService.upload(file, {
        timeZone: facts.timeZone,
        includePrivateSessions: includePrivate,
        signal: controller.signal,
        onProgress: (progress) => {
          percent = Math.max(percent, percentFor(progress))
          setState((current) =>
            current.kind === 'uploading' && run === runRef.current ? { ...current, progress, percent } : current,
          )
        },
      })
      if (run !== runRef.current) return
      parserRef.current.terminate()
      setState({ kind: result.playlistError ? 'partial' : 'done', file, facts, result })
      await onRefresh()
    } catch {
      if (run !== runRef.current) return
      parserRef.current.terminate()
      setState(controller.signal.aborted ? { kind: 'inventory', file, facts } : { kind: 'upload-failed', file, facts })
    } finally {
      if (controllerRef.current === controller) controllerRef.current = null
    }
  }

  function cancel() {
    if (state.kind !== 'uploading') return
    const { file, facts } = state
    supersede()
    parserRef.current.terminate()
    setState({ kind: 'inventory', file, facts })
  }

  function backToInventory() {
    if (state.kind !== 'upload-failed') return
    setState({ kind: 'inventory', file: state.file, facts: state.facts })
  }

  async function copyReport(report: string) {
    const clipboard = typeof navigator === 'undefined' ? undefined : navigator.clipboard
    if (!clipboard || typeof clipboard.writeText !== 'function') {
      setCopyStatus(COPY_UNAVAILABLE)
      return
    }
    try {
      await clipboard.writeText(report)
      setCopyStatus('Report copied.')
    } catch {
      setCopyStatus(COPY_UNAVAILABLE)
    }
  }

  function onPick(event: ChangeEvent<HTMLInputElement>) {
    const file = event.currentTarget.files?.[0]
    if (file) void take(file)
  }

  function onDragOver(event: DragEvent<HTMLElement>) {
    event.preventDefault()
    setDragOver(true)
  }

  function onDrop(event: DragEvent<HTMLElement>) {
    event.preventDefault()
    setDragOver(false)
    const file = event.dataTransfer?.files?.[0]
    if (file) void take(file)
  }

  if (state.kind === 'pick') {
    return (
      <div
        className={`drop ${dragOver ? 'drop--over' : ''}`}
        role="region"
        aria-label="Import a Spotify ZIP"
        tabIndex={-1}
        ref={rootRef as Ref<HTMLDivElement>}
        onDragEnter={onDragOver}
        onDragOver={onDragOver}
        onDragLeave={() => setDragOver(false)}
        onDrop={onDrop}
      >
        <div>
          <strong>Drop a Spotify ZIP here</strong>
          <span>
            or{' '}
            <label className="file-pick">
              choose a file
              <input className="sr-only" type="file" accept=".zip,application/zip" onChange={onPick} />
            </label>{' '}
            · either package, in any order
          </span>
        </div>
      </div>
    )
  }

  const { file } = state
  let mark = 'ZIP'
  let title = file.name
  let subtitle = ''
  let chip: { tone: ChipTone; label: string; announce?: string }
  let tone = ''

  switch (state.kind) {
    case 'inspecting': {
      subtitle = 'Reading on this device'
      chip = { tone: 'wait', label: 'Reading', announce: stageLabel(state.progress).announce }
      break
    }
    case 'inventory': {
      subtitle = `${formatBytes(file.size)} · ${packageLabel(state.facts.package)}`
      chip = { tone: 'ok', label: 'Readable' }
      break
    }
    case 'uploading': {
      subtitle = 'Reading and uploading on this device'
      chip = { tone: 'wait', label: `Uploading ${state.percent}%`, announce: stageLabel(state.progress).announce }
      break
    }
    case 'done': {
      const { summary } = state.result
      mark = '✓'
      if (state.facts.package === 'spotify_extended') {
        title = 'Extended history imported'
        const years = yearsLabel(summary.ledgerFrom, summary.ledgerTo)
        subtitle = [years, plural(summary.tracks, 'track'), plural(summary.days, 'day')].filter(Boolean).join(' · ')
        chip = { tone: 'ok', label: 'Done', announce: `import complete, ${plural(summary.tracks, 'track')}` }
      } else {
        title = 'Account data imported'
        const playlists = state.result.playlists?.playlists ?? 0
        const liked = plural(summary.libraryTracks, 'liked song')
        subtitle = `${liked} · ${plural(summary.artists, 'artist')} · ${plural(playlists, 'playlist')}`
        chip = { tone: 'ok', label: 'Done', announce: `import complete, ${liked}` }
      }
      break
    }
    case 'partial': {
      mark = '!'
      tone = 'attention'
      title = 'Account data imported, playlists didn’t land'
      subtitle = 'Likes and followed artists are in. The playlist sync was interrupted.'
      chip = { tone: 'wait', label: 'Partly done', announce: 'playlists didn’t land' }
      break
    }
    case 'upload-failed': {
      mark = '!'
      tone = 'attention'
      title = 'Upload interrupted'
      subtitle = 'Nothing was published'
      chip = { tone: 'err', label: 'Failed', announce: 'upload interrupted, nothing was published' }
      break
    }
    case 'unreadable': {
      tone = 'err'
      subtitle = 'Couldn’t read this export'
      chip = { tone: 'err', label: 'Unreadable', announce: 'couldn’t read this export' }
      break
    }
  }

  return (
    <section
      className={`card import-card ${tone}`}
      aria-label="Import a Spotify ZIP"
      tabIndex={-1}
      ref={rootRef as Ref<HTMLElement>}
    >
      <div className="source-row">
        <span className="source-mark" aria-hidden="true">
          {mark}
        </span>
        <span className="source-copy">
          <strong>{title}</strong>
          <small>{subtitle}</small>
        </span>
        <Chip tone={chip.tone} label={chip.label} announce={chip.announce} />
      </div>

      {state.kind === 'inspecting' ? (
        <p className="note">{stageLabel(state.progress).line} · nothing leaves this device yet</p>
      ) : null}

      {state.kind === 'inventory' ? (
        <>
          <div className="inventory">
            <Definitions rows={inventoryRows(state.facts)} />
            <FileList inventory={state.facts.inventory} />
          </div>
          {state.facts.package === 'spotify_extended' ? (
            <div className="toggle">
              <button
                className="switch"
                type="button"
                role="switch"
                aria-checked={includePrivate}
                aria-label="Include private sessions"
                onClick={() => setIncludePrivate((value) => !value)}
              />
              <span>
                Include private sessions{' '}
                <span className="note note--inline">
                  · Plays hidden from followers stay out unless you choose otherwise.
                </span>
              </span>
            </div>
          ) : null}
          <p className="note">
            Only these plays leave this device. Your account details, payments, and IP addresses are never read.
          </p>
          <div className="btn-row">
            <button className="btn primary" type="button" onClick={() => void upload()}>
              Upload
            </button>
            <button className="btn" type="button" onClick={reset}>
              Choose a different file
            </button>
          </div>
        </>
      ) : null}

      {state.kind === 'uploading' ? (
        <>
          <div className="progress" aria-hidden="true">
            <span style={{ width: `${state.percent}%` }} />
          </div>
          <p className="note">
            {stageLabel(state.progress).line} · {NOTHING_OPEN}
          </p>
          <div className="btn-row">
            <button className="btn danger" type="button" onClick={cancel}>
              Cancel
            </button>
          </div>
        </>
      ) : null}

      {state.kind === 'done' ? (
        <>
          <div className="inventory">
            <Definitions
              rows={
                state.facts.package === 'spotify_extended'
                  ? [
                      ['Plays counted', formatCount(state.result.plays)],
                      ['Unresolved', unresolvedLabel(state.result.summary.unresolvedRows)],
                      ['Ledger', ledgerLabel(state.result.summary)],
                      ['Enriching', 'your most-played first'],
                    ]
                  : [
                      ['Liked songs', formatCount(state.result.summary.libraryTracks)],
                      ['Artists', formatCount(state.result.summary.artists)],
                      ['Playlists', formatCount(state.result.playlists?.playlists ?? 0)],
                      ['Enriching', 'your liked songs first'],
                    ]
              }
            />
          </div>
          <p className="note">
            The DJ starts with what it knows best. More detail arrives over the next hours as tracks are enriched.
          </p>
          <div className="btn-row">
            <button className="btn primary" type="button" onClick={onNewTape}>
              Make your first mix
            </button>
            <button className="btn" type="button" onClick={reset}>
              {state.facts.package === 'spotify_extended'
                ? 'Import the account data too'
                : 'Import the extended history too'}
            </button>
          </div>
        </>
      ) : null}

      {state.kind === 'partial' ? (
        <>
          <p>
            Your liked songs and artists are safe on the server. Nothing is lost and nothing needs re-uploading; the
            playlists can follow later.
          </p>
          <div className="btn-row">
            <button className="btn primary" type="button" onClick={onNewTape}>
              Make a mix anyway
            </button>
            <button className="btn" type="button" onClick={reset}>
              Choose a different file
            </button>
          </div>
        </>
      ) : null}

      {state.kind === 'upload-failed' ? (
        <>
          <p>
            The upload stopped before anything was published, so nothing was kept from this attempt. Check your
            connection and try again; the file is still read on this device only.
          </p>
          <div className="btn-row">
            <button className="btn primary" type="button" onClick={backToInventory}>
              Try again
            </button>
            <button className="btn" type="button" onClick={reset}>
              Choose a different file
            </button>
          </div>
        </>
      ) : null}

      {state.kind === 'unreadable' ? (
        <>
          <p>{unreadableCopy(state)}</p>
          {state.report !== null ? (
            <>
              <pre className="diag">{state.report}</pre>
              <p className="note">
                The report lists file names, sizes, and row counts only. No song, artist, or personal data.
              </p>
            </>
          ) : (
            <p className="note">No report could be built because the file isn’t a ZIP archive.</p>
          )}
          {copyStatus ? (
            <p className="note" aria-live="polite">
              {copyStatus}
            </p>
          ) : null}
          <div className="btn-row">
            {state.report !== null ? (
              <button className="btn primary" type="button" onClick={() => void copyReport(state.report!)}>
                Copy report
              </button>
            ) : null}
            <button className="btn" type="button" onClick={reset}>
              Try another file
            </button>
          </div>
        </>
      ) : null}
    </section>
  )
}

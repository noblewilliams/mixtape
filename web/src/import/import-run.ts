// One file's journey from pick to summary, owned by the app for the
// signed-in user's life rather than by the panel that shows it: leaving the
// import page mid-upload (Home, a session, a new tape) unmounts the panel
// but never cancels the run, and coming back shows wherever it got to. The
// panel subscribes through useSyncExternalStore and renders the state; the
// run owns the AbortController, the parser's lifetime (a Worker exists only
// between the first read of a file and cancel or finish), and the one-run
// gate. Nothing here logs: the snapshot carries track, artist, and playlist
// names.

import { formatDiagnosticsReport } from './diagnostics-report'
import type {
  InspectedExport,
  ListeningImportProgress,
  ListeningImportResult,
  ListeningImportService,
} from './import-service'
import type { PageParser } from './page-parser'
import type { ExportInventory, ListeningExportPackage } from './snapshot'
import { isWorkerFailure } from './worker-client'

/** What the inventory shows: the listing plus the counts the inspect parse gives. */
export type ImportFacts = {
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

/** A file that parsed, with the choice made on the inventory card; carried through every later state. */
type Loaded = {
  file: File
  facts: ImportFacts
  inspected: InspectedExport
  includePrivate: boolean
}

export type ImportRunState =
  | { kind: 'pick' }
  | { kind: 'inspecting'; file: File; progress: ListeningImportProgress | null }
  | ({ kind: 'inventory' } & Loaded)
  | ({ kind: 'uploading'; progress: ListeningImportProgress | null; percent: number } & Loaded)
  | ({ kind: 'done'; result: ListeningImportResult } & Loaded)
  | ({ kind: 'partial'; result: ListeningImportResult } & Loaded)
  | ({ kind: 'upload-failed' } & Loaded)
  /** The parser itself could not run on this device (the Worker failed to load or died). */
  | { kind: 'read-failed'; file: File }
  | {
      kind: 'unreadable'
      file: File
      /** False when the file could not even be opened as a ZIP. */
      zip: boolean
      brokenFile: string | null
      report: string | null
    }

export type ImportRun = {
  getState(): ImportRunState
  subscribe(listener: () => void): () => void
  /** Read a picked or dropped file on this device; supersedes whatever was running. */
  take(file: File): void
  /** The private-sessions switch on the inventory card. */
  setIncludePrivate(value: boolean): void
  /** Upload the inventory as shown. */
  upload(): void
  /** Re-run the whole import for the partial state's file and options; idempotent server-side. */
  retry(): void
  /** Stop an upload and return to its inventory. */
  cancel(): void
  /** From upload-failed back to the inventory; from read-failed, read the same file again. */
  tryAgain(): void
  /** Back to the drop zone, releasing the parser. */
  reset(): void
  /** Abort anything in flight, release the parser, and forget the run (sign-out, app unmount). */
  dispose(): void
}

type ImportRunDeps = {
  importService: ListeningImportService
  parser: PageParser
  /** Called once a run has published (done or partial); its failure never changes the run's state. */
  onImported: () => Promise<void> | void
}

export function deviceTimeZone(): string {
  try {
    return Intl.DateTimeFormat().resolvedOptions().timeZone || 'UTC'
  } catch {
    return 'UTC'
  }
}

function factsFrom({ inventory, snapshot, timeZone }: InspectedExport): ImportFacts {
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

type ParseStep = Extract<ListeningImportProgress, { file: string | null }>

export function isParseProgress(progress: ListeningImportProgress): progress is ParseStep {
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

export function percentFor(progress: ListeningImportProgress): number {
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

const loadedOf = ({ file, facts, inspected, includePrivate }: Loaded): Loaded => ({ file, facts, inspected, includePrivate })

export function createImportRun({ importService, parser, onImported }: ImportRunDeps): ImportRun {
  let state: ImportRunState = { kind: 'pick' }
  let controller: AbortController | null = null
  // Bumped whenever a run is superseded (cancel, reset, dispose) so a late
  // rejection from the old run never writes over the new state.
  let generation = 0
  const listeners = new Set<() => void>()

  function set(next: ImportRunState) {
    state = next
    for (const listener of [...listeners]) listener()
  }

  function supersede(): number {
    generation += 1
    controller?.abort()
    controller = null
    return generation
  }

  function begin(): { run: number; signal: AbortSignal; settle: () => void } {
    const run = supersede()
    const own = new AbortController()
    controller = own
    return {
      run,
      signal: own.signal,
      settle: () => {
        if (controller === own) controller = null
      },
    }
  }

  function readFailed(file: File) {
    parser.terminate()
    set({ kind: 'read-failed', file })
  }

  async function fail(run: number, file: File, error: unknown, signal: AbortSignal) {
    if (isWorkerFailure(error)) {
      readFailed(file)
      return
    }
    const unreadable = asUnreadable(error)
    let report: string | null = null
    try {
      const diagnostics = await parser.diagnose(file, { signal })
      report = formatDiagnosticsReport(diagnostics, unreadable?.inventory ?? null)
    } catch (diagnoseError) {
      if (run !== generation) return
      if (isWorkerFailure(diagnoseError)) {
        readFailed(file)
        return
      }
      report = null
    }
    if (run !== generation) return
    parser.terminate()
    set({
      kind: 'unreadable',
      file,
      zip: unreadable !== null || report !== null,
      brokenFile: unreadable?.file ?? null,
      report,
    })
  }

  async function inspect(file: File) {
    const { run, signal, settle } = begin()
    set({ kind: 'inspecting', file, progress: null })
    try {
      const inspected = await importService.inspect(file, {
        timeZone: deviceTimeZone(),
        signal,
        onProgress: (progress) => {
          if (run === generation && state.kind === 'inspecting') set({ ...state, progress })
        },
      })
      if (run !== generation) return
      set({ kind: 'inventory', file, facts: factsFrom(inspected), inspected, includePrivate: false })
    } catch (error) {
      if (run !== generation || signal.aborted) return
      await fail(run, file, error, signal)
    } finally {
      settle()
    }
  }

  async function send(loaded: Loaded) {
    const { run, signal, settle } = begin()
    let percent = 0
    set({ kind: 'uploading', ...loaded, progress: null, percent })
    try {
      const result = await importService.upload(loaded.file, {
        timeZone: loaded.facts.timeZone,
        includePrivateSessions: loaded.includePrivate,
        inspected: loaded.inspected,
        signal,
        onProgress: (progress) => {
          percent = Math.max(percent, percentFor(progress))
          if (run === generation && state.kind === 'uploading') set({ ...state, progress, percent })
        },
      })
      if (run !== generation) return
      parser.terminate()
      set({ kind: result.playlistError ? 'partial' : 'done', ...loaded, result })
    } catch (error) {
      if (run !== generation) return
      parser.terminate()
      if (signal.aborted) set({ kind: 'inventory', ...loaded })
      else if (isWorkerFailure(error)) set({ kind: 'read-failed', file: loaded.file })
      else set({ kind: 'upload-failed', ...loaded })
      return
    } finally {
      settle()
    }
    // The import is published by now: a refresh that fails leaves the
    // summary standing, and the page's own onboarding read reports it.
    try {
      await onImported()
    } catch {
      // The summary stands.
    }
  }

  return {
    getState: () => state,
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
    take(file) {
      void inspect(file)
    },
    setIncludePrivate(value) {
      if (state.kind === 'inventory') set({ ...state, includePrivate: value })
    },
    upload() {
      if (state.kind === 'inventory') void send(loadedOf(state))
    },
    retry() {
      if (state.kind === 'partial') void send(loadedOf(state))
    },
    cancel() {
      if (state.kind !== 'uploading') return
      const loaded = loadedOf(state)
      supersede()
      parser.terminate()
      set({ kind: 'inventory', ...loaded })
    },
    tryAgain() {
      if (state.kind === 'upload-failed') set({ kind: 'inventory', ...loadedOf(state) })
      else if (state.kind === 'read-failed') void inspect(state.file)
    },
    reset() {
      supersede()
      parser.terminate()
      set({ kind: 'pick' })
    },
    dispose() {
      supersede()
      parser.terminate()
      if (state.kind !== 'pick') set({ kind: 'pick' })
    },
  }
}

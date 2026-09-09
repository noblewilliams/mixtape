import { Uint8ArrayReader, Uint8ArrayWriter, ZipWriter } from '@zip.js/zip.js'
import { CollectionReview, selectionCanUpload } from './CollectionReview'
// The import page: pick or drop a ZIP, read it on this device, show exactly
// what will leave it, upload with live progress, then the summary. The run
// itself (state, abort, parser lifetime) lives in the app's ImportRun so
// leaving this page never cancels an upload; this panel renders whatever
// state the run is in and forwards the controls.
// Nothing here logs: the snapshot carries track, artist, and playlist names.

import {
  Fragment,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
  useSyncExternalStore,
  type ChangeEvent,
  type DragEvent,
  type Ref,
} from 'react'
import { formatBytes, formatCount } from '../import/diagnostics-report'
import {
  isParseProgress,
  type ImportFacts,
  type ImportRun,
  type ImportRunState,
} from '../import/import-run'
import {
  LISTENING_ARTIST_CHUNK,
  LISTENING_DAY_CHUNK,
  LISTENING_LIBRARY_CHUNK,
  LISTENING_TRACK_CHUNK,
  type ListeningImportProgress,
  type ListeningImportResult,
} from '../import/import-service'
import type {
  ExportInventory,
  ListeningExportPackage,
} from '../import/snapshot'
import { ledgerRangeLabel } from '../lib/onboarding'

export type ImportPanelHandle = {
  /** Back to the drop zone (when no upload is running) and focus it. */
  focus(): void
}

type ImportPanelProps = {
  uploadBlocked?: boolean
  run: ImportRun
  onNewTape: () => void
  mixLabel?: string
  ref?: Ref<ImportPanelHandle>
}

const EXPECTED_FILES =
  'Use an Exportify ZIP or CSV, or an official Spotify ZIP. Import Exportify and official files separately. Official files: Streaming_History_Audio_*.json, YourLibrary.json, Playlist*.json.'
const COPY_UNAVAILABLE =
  'Copy isn’t available here. Select the report and copy it by hand.'
const NOTHING_OPEN = 'nothing needs to stay open in Spotify'

const baseName = (path: string): string => path.slice(path.lastIndexOf('/') + 1)

function yearsLabel(from: string | null, to: string | null): string | null {
  if (!from) return null
  const start = from.slice(0, 4)
  const end = (to ?? from).slice(0, 4)
  return start === end ? start : `${start} – ${end}`
}

function packageLabel(pkg: ListeningExportPackage): string {
  return pkg === 'spotify_exportify'
    ? 'Exportify saved music'
    : pkg === 'spotify_extended'
      ? 'Extended streaming history'
      : 'Account data'
}

function plural(count: number, noun: string): string {
  return `${formatCount(count)} ${noun}${count === 1 ? '' : 's'}`
}

const unresolvedLabel = (rows: number): string =>
  rows === 0 ? 'None' : plural(rows, 'row')

/** "3 podcasts · 9 local files": zero parts omitted, "None" when nothing was skipped. */
function skippedRowsLabel(facts: ImportFacts): string {
  if (facts.package !== 'spotify_extended')
    return facts.unresolvedRows === 0
      ? 'None'
      : formatCount(facts.unresolvedRows)
  const parts = [
    facts.stats.podcastOrAudiobook > 0
      ? plural(facts.stats.podcastOrAudiobook, 'podcast')
      : null,
    facts.stats.localFile > 0
      ? plural(facts.stats.localFile, 'local file')
      : null,
  ].filter((part): part is string => part !== null)
  return parts.length === 0 ? 'None' : parts.join(' · ')
}

/** The note beside the private-sessions switch: what flipping it would add. */
function privateSessionsNote(privatePlays: number): string {
  if (privatePlays === 0) return '· No private-session plays in this file.'
  const verb = privatePlays === 1 ? 'stays' : 'stay'
  return `· ${plural(privatePlays, 'play')} hidden from followers ${verb} out unless you choose otherwise.`
}

const ledgerLabel = (summary: ListeningImportResult['summary']): string =>
  ledgerRangeLabel(summary.ledgerFrom, summary.ledgerTo) ?? '—'

const UPLOAD_NOUNS: Record<string, [noun: string, chunk: number]> = {
  uploading_tracks: ['tracks', LISTENING_TRACK_CHUNK],
  uploading_days: ['days', LISTENING_DAY_CHUNK],
  uploading_library: ['liked songs', LISTENING_LIBRARY_CHUNK],
  uploading_artists: ['artists', LISTENING_ARTIST_CHUNK],
}

/** The stage line under the band, and the shorter form the chip announces. */
function stageLabel(progress: ListeningImportProgress | null): {
  line: string
  announce: string
} {
  if (progress === null)
    return { line: 'Reading the archive', announce: 'reading' }
  if (isParseProgress(progress)) {
    if (progress.stage === 'listing')
      return { line: 'Reading the archive', announce: 'reading' }
    if (progress.stage === 'reading') {
      const part = `files ${progress.completed} of ${progress.total}`
      return { line: `Reading ${part}`, announce: part }
    }
    return {
      line: `Read ${plural(progress.total, 'file')}, starting the upload`,
      announce: 'starting the upload',
    }
  }
  if (progress.stage === 'complete')
    return { line: 'Finishing', announce: 'finishing' }
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

function unreadableCopy(
  state: Extract<ImportRunState, { kind: 'unreadable' }>,
): string {
  if (!state.zip) {
    return (
      'This file couldn’t be opened as a ZIP, so nothing was uploaded. ' +
      `Give Mixtape the ZIP Spotify emailed, unchanged. ${EXPECTED_FILES}`
    )
  }
  if (state.brokenFile === null) {
    return `This ZIP holds none of the Spotify export files, so nothing was uploaded. ${EXPECTED_FILES}`
  }
  const which = /^streaming_history_audio_/i.test(state.brokenFile)
    ? 'One of the history files'
    : 'One of the files'
  return `${which} couldn’t be read, so nothing was uploaded. ${EXPECTED_FILES}`
}

type ChipTone = 'ok' | 'wait' | 'err'

function Chip({
  tone,
  label,
  announce,
}: {
  tone: ChipTone
  label: string
  announce?: string
}) {
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
          <span className="file-name">{baseName(file.path)}</span>{' '}
          <span className="file-label">ignored</span>
        </li>
      ))}
    </ul>
  )
}

function inventoryRows(facts: ImportFacts): [string, string][] {
  const skipped = skippedRowsLabel(facts)
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

export function ImportPanel({
  run,
  onNewTape,
  mixLabel = 'Make your first mix',
  ref,
  uploadBlocked = false,
}: ImportPanelProps) {
  const state = useSyncExternalStore(run.subscribe, run.getState)
  const [dragOver, setDragOver] = useState(false)
  const [copyStatus, setCopyStatus] = useState('')
  const rootRef = useRef<HTMLElement>(null)
  const pendingFocus = useRef(false)

  useEffect(() => {
    if (state.kind !== 'pick' || !pendingFocus.current) return
    pendingFocus.current = false
    rootRef.current?.scrollIntoView?.({ block: 'center' })
    rootRef.current?.focus()
  }, [state.kind])

  function reset() {
    setCopyStatus('')
    run.reset()
  }

  useImperativeHandle(
    ref,
    () => ({
      focus() {
        const current = run.getState()
        if (current.kind === 'uploading' || current.kind === 'inspecting') {
          rootRef.current?.scrollIntoView?.({ block: 'center' })
          return
        }
        if (current.kind === 'pick') {
          rootRef.current?.scrollIntoView?.({ block: 'center' })
          rootRef.current?.focus()
          return
        }
        pendingFocus.current = true
        reset()
      },
    }),
    [run],
  )

  function take(file: File) {
    setCopyStatus('')
    run.take(file)
  }

  async function copyReport(report: string) {
    const clipboard =
      typeof navigator === 'undefined' ? undefined : navigator.clipboard
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

  async function takeFiles(files: File[]) {
    if (files.length === 1) {
      take(files[0])
      return
    }
    if (!files.length) return
    if (
      files.some((f) => !/\.csv$/i.test(f.name)) ||
      files.length > 2000 ||
      files.reduce((n, f) => n + f.size, 0) > 64 * 1024 * 1024
    ) {
      setCopyStatus(
        'Choose one ZIP, or several CSV files together. Keep Exportify and official exports separate.',
      )
      return
    }
    const writer = new ZipWriter(new Uint8ArrayWriter(), {
      useWebWorkers: false,
    })
    try {
      for (const [i, f] of files.entries())
        await writer.add(
          `${i}/${f.name}`,
          new Uint8ArrayReader(new Uint8Array(await f.arrayBuffer())),
          { level: 0 },
        )
      take(
        new File(
          [new Uint8Array(await writer.close()).buffer],
          'selected_playlists.zip',
          {
            type: 'application/zip',
          },
        ),
      )
    } catch {
      setCopyStatus('Could not open those files. Choose them again.')
    }
  }
  function onPick(event: ChangeEvent<HTMLInputElement>) {
    void takeFiles(Array.from(event.currentTarget.files ?? []))
  }

  function onDragOver(event: DragEvent<HTMLElement>) {
    event.preventDefault()
    setDragOver(true)
  }

  function onDrop(event: DragEvent<HTMLElement>) {
    event.preventDefault()
    setDragOver(false)
    void takeFiles(Array.from(event.dataTransfer?.files ?? []))
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
          {copyStatus ? <p role="alert">{copyStatus}</p> : null}
          <strong>Choose files</strong>
          <span>
            or{' '}
            <label className="file-pick">
              choose files
              <input
                className="sr-only"
                type="file"
                accept=".zip,.csv,application/zip,text/csv"
                multiple
                onChange={onPick}
              />
            </label>{' '}
            · Exportify ZIP or CSV files, or an official Spotify ZIP
          </span>
        </div>
      </div>
    )
  }

  const { file } = state
  let mark = state.file.name.toLowerCase().endsWith('.csv') ? 'CSV' : 'ZIP'
  let title = file.name
  let subtitle = ''
  let chip: { tone: ChipTone; label: string; announce?: string }
  let tone = ''

  switch (state.kind) {
    case 'inspecting': {
      subtitle = 'Reading on this device'
      chip = {
        tone: 'wait',
        label: 'Reading',
        announce: stageLabel(state.progress).announce,
      }
      break
    }
    case 'inventory': {
      subtitle = `${formatBytes(file.size)} · ${packageLabel(state.facts.package)}`
      chip = { tone: 'ok', label: 'Readable' }
      break
    }
    case 'uploading': {
      subtitle = 'Reading and uploading on this device'
      chip = {
        tone: 'wait',
        label: `Uploading ${state.percent}%`,
        announce: stageLabel(state.progress).announce,
      }
      break
    }
    case 'done': {
      const { summary } = state.result
      mark = '✓'
      if (state.facts.package === 'spotify_extended') {
        title = 'Extended history imported'
        const years = yearsLabel(summary.ledgerFrom, summary.ledgerTo)
        subtitle = [
          years,
          plural(summary.tracks, 'track'),
          plural(summary.days, 'day'),
        ]
          .filter(Boolean)
          .join(' · ')
        chip = {
          tone: 'ok',
          label: 'Done',
          announce: `import complete, ${plural(summary.tracks, 'track')}`,
        }
      } else {
        title =
          state.facts.package === 'spotify_exportify'
            ? 'Spotify music imported'
            : 'Account data imported'
        const playlists = state.result.playlists?.playlists ?? 0
        const liked = plural(summary.libraryTracks, 'liked song')
        subtitle = `${liked} · ${plural(summary.artists, 'artist')} · ${plural(playlists, 'playlist')}`
        chip = {
          tone: 'ok',
          label: 'Done',
          announce: `import complete, ${liked}`,
        }
      }
      break
    }
    case 'partial': {
      mark = '!'
      tone = 'attention'
      title =
        state.facts.package === 'spotify_exportify'
          ? 'Saved music imported, playlists need attention'
          : 'Account data imported, playlists didn’t land'
      subtitle =
        state.facts.package === 'spotify_exportify'
          ? 'The saved-song step finished. Review and retry the playlists.'
          : 'Likes and followed artists are in. The playlist sync was interrupted.'
      chip = {
        tone: 'wait',
        label: 'Partly done',
        announce: 'playlists didn’t land',
      }
      break
    }
    case 'upload-failed': {
      mark = '!'
      tone = 'attention'
      title = 'Upload interrupted'
      subtitle = state.conflict
        ? 'Your current collection was kept'
        : 'Import could not be confirmed'
      chip = {
        tone: 'err',
        label: 'Failed',
        announce: 'import interrupted',
      }
      break
    }
    case 'read-failed': {
      mark = '!'
      tone = 'err'
      subtitle = 'Nothing was uploaded'
      chip = {
        tone: 'err',
        label: 'Not read',
        announce: 'couldn’t read this file on this device',
      }
      break
    }
    case 'unreadable': {
      tone = 'err'
      subtitle = 'Couldn’t read this export'
      chip = {
        tone: 'err',
        label: 'Unreadable',
        announce: 'couldn’t read this export',
      }
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
        <div className="source-actions">
          <Chip tone={chip.tone} label={chip.label} announce={chip.announce} />
          {state.kind === 'uploading' || state.kind === 'inspecting' ? (
            <button
              className="btn text-action"
              type="button"
              onClick={state.kind === 'uploading' ? run.cancel : reset}
            >
              Cancel
            </button>
          ) : null}
        </div>
      </div>

      {state.kind === 'inspecting' ? (
        <p className="note">
          {stageLabel(state.progress).line} · nothing leaves this device yet
        </p>
      ) : null}

      {state.kind === 'inventory' ? (
        <>
          {state.inspected.selection ? (
            <CollectionReview
              inventory={state.inspected.inventory}
              snapshot={state.inspected.snapshot}
              selection={state.inspected.selection}
              onChange={run.setSelection}
            />
          ) : null}
          {!state.inspected.selection ? (
            <div className="inventory">
              <Definitions rows={inventoryRows(state.facts)} />
              <FileList inventory={state.facts.inventory} />
            </div>
          ) : null}
          {state.facts.package === 'spotify_extended' ? (
            <label className="toggle">
              <button
                className="switch"
                type="button"
                role="switch"
                aria-checked={state.includePrivate}
                aria-label="Include private sessions"
                onClick={() => run.setIncludePrivate(!state.includePrivate)}
              />
              <span>
                Include private sessions{' '}
                <span className="note note--inline">
                  {privateSessionsNote(state.facts.stats.privatePlays)}
                </span>
              </span>
            </label>
          ) : null}
          <p className="note">
            Only reviewed music leaves this device. Your account details,
            payments, and IP addresses are never read.
          </p>
          <div className="btn-row">
            <button
              className="btn primary"
              type="button"
              disabled={
                uploadBlocked ||
                !selectionCanUpload(
                  state.inspected.snapshot,
                  state.inspected.selection,
                )
              }
              onClick={run.upload}
            >
              Upload
            </button>
            {uploadBlocked ? (
              <p className="note" role="status">
                Apple sync is still running or checking its result. You can
                inspect this file now; upload after that sync finishes.
              </p>
            ) : null}
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
                      [
                        'Unresolved',
                        unresolvedLabel(state.result.summary.unresolvedRows),
                      ],
                      ['Ledger', ledgerLabel(state.result.summary)],
                      ['Enriching', 'your most-played first'],
                    ]
                  : [
                      [
                        'Liked songs',
                        formatCount(state.result.summary.libraryTracks),
                      ],
                      ['Artists', formatCount(state.result.summary.artists)],
                      [
                        'Playlists',
                        formatCount(state.result.playlists?.playlists ?? 0),
                      ],
                      ['Enriching', 'your liked songs first'],
                    ]
              }
            />
          </div>
          <p className="note">
            The DJ starts with what it knows best. More detail arrives over the
            next hours as tracks are enriched.
          </p>
          <div className="btn-row">
            <button className="btn primary" type="button" onClick={onNewTape}>
              {mixLabel}
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
            Your liked songs and artists are safe on the server. Nothing is
            lost; the playlists can follow with a retry.
          </p>
          <p className="note">Re-uploads the file; nothing is duplicated.</p>
          <div className="btn-row">
            <button
              className="btn primary"
              type="button"
              disabled={uploadBlocked}
              onClick={
                state.result.playlistError &&
                'status' in state.result.playlistError &&
                state.result.playlistError.status === 409
                  ? run.reviewAgain
                  : run.retry
              }
            >
              {state.result.playlistError &&
              'status' in state.result.playlistError &&
              state.result.playlistError.status === 409
                ? 'Review again'
                : 'Retry playlists'}
            </button>
            <button className="btn" type="button" onClick={onNewTape}>
              {mixLabel}
            </button>
          </div>
        </>
      ) : null}

      {state.kind === 'upload-failed' ? (
        <>
          <p>
            {state.conflict
              ? 'The collection changed after your review. We kept the current version. Review again before replacing it.'
              : 'We could not confirm the import. Check your connection and try again; completed steps are safe to repeat.'}
          </p>
          <div className="btn-row">
            <button
              className="btn primary"
              type="button"
              onClick={run.tryAgain}
            >
              Try again
            </button>
            <button className="btn" type="button" onClick={reset}>
              Choose a different file
            </button>
          </div>
        </>
      ) : null}

      {state.kind === 'read-failed' ? (
        <>
          <p>
            {state.review
              ? 'Your file was read, but we couldn’t load your current collections. Check your connection and try again.'
              : 'Couldn’t read this file on this device. Try again.'}
          </p>
          <div className="btn-row">
            <button
              className="btn primary"
              type="button"
              onClick={run.tryAgain}
            >
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
                The report lists file names, sizes, and row counts only. No
                song, artist, or personal data.
              </p>
            </>
          ) : (
            <p className="note">
              No report could be built because the file isn’t a ZIP archive.
            </p>
          )}
          <p className="note copy-status" aria-live="polite">
            {copyStatus}
          </p>
          <div className="btn-row">
            {state.report !== null ? (
              <button
                className="btn primary"
                type="button"
                onClick={() => void copyReport(state.report!)}
              >
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

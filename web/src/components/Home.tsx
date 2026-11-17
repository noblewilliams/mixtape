import { EmptyState, MixSkeletons } from './UiStates'
import { SessionRow, SharedRow } from './SessionControls'
import { TapeRack } from './TapeRack'
import { Tabs } from './Tabs'
import { ViewSwitch } from './ViewSwitch'
import type { CollectionView, DjSession, ListenLaterEntry, SharedMixRow } from '../domain'
import { durationLabel } from '../api/mappers'
import { mergeSharedRows, type MixesItem } from '../lib/mixes-list'
import { useEffect, useRef, useState, type ReactNode } from 'react'
import { ControlModal } from './ControlModal'
import { NewTapeCompactButton } from './TapeActions'
import { ListenLaterList, type ListenLaterActions } from './ListenLaterList'

export type MixesTab = 'active' | 'archived' | 'listen-later'

export type ShelfProps = ListenLaterActions & {
  /** Null until the first read lands. */
  entries: ListenLaterEntry[] | null
  error?: string
  spotifyOnly: boolean
  busy?: boolean
  pendingIds?: string[]
  onRetry: () => void
  onFindAlbum: () => void
}

type HomeProps = {
  loading?: boolean
  error?: string
  onRetry?: () => void
  onColor?: (id: string, color: string) => Promise<void>
  player?: ReactNode
  suggestions?: ReactNode
  tab?: MixesTab
  onTab?: (tab: MixesTab) => void
  /** The Listen later tab exists only while album picks are on for this listener. */
  albumPicks?: boolean
  shelf?: ShelfProps
  onRename?: (id: string, title: string) => Promise<void>
  onArchive?: (id: string) => Promise<void>
  onRestore?: (id: string) => Promise<void>
  sessions: DjSession[]
  /** Shares this listener saved (GET /me/shared-mixes): rows among the active mixes, by time. */
  sharedRows?: SharedMixRow[]
  onOpenShared?: (token: string) => void
  onRemoveShared?: (token: string) => Promise<void>
  collectionView: CollectionView
  onChangeCollectionView: (view: CollectionView) => void
  onOpenSession: (id: string) => void
  onNewTape: () => void
  /** Select mode (approved board 2026-11-16): archive or unarchive several; answers the ids that failed. */
  onArchiveMany?: (ids: string[], status: 'archived' | 'active') => Promise<string[]>
  /** POST /sessions/delete; answers 'sign_in_required' when the server refuses an anonymous listener, throws on failure. */
  onDeleteMany?: (ids: string[]) => Promise<'deleted' | 'sign_in_required'>
  /** Anonymous listeners can archive but not delete: Delete asks them to sign in. */
  anonymous?: boolean
  onSignIn?: () => void
  /** What the client knows of a mix's active share and a turn in flight, for the confirm's extra lines. */
  isShared?: (id: string) => boolean
  isWorking?: (id: string) => boolean
}

function countLine(count: number, archived: boolean) {
  return `${count} ${archived ? 'archived ' : ''}${count === 1 ? 'mix' : 'mixes'}${count ? ' · recently updated' : ''}`
}

/** Board W6: "4 albums saved · 2 listened"; saved counts what is still waiting, the listened part only when there is one. */
function shelfCountLine(entries: ListenLaterEntry[]) {
  const listened = entries.filter((entry) => entry.listenedAt !== null).length
  const saved = entries.length - listened
  return `${saved} ${saved === 1 ? 'album' : 'albums'} saved${listened ? ` · ${listened} listened` : ''}`
}

export function Home({
  loading = false, error, onRetry, onColor, player, suggestions, sessions, sharedRows = [], onOpenShared, onRemoveShared, tab: requestedTab = 'active', onTab, albumPicks = false, shelf, onRename, onArchive, onRestore,
  collectionView,
  onChangeCollectionView,
  onOpenSession,
  onNewTape,
  onArchiveMany,
  onDeleteMany,
  anonymous = false,
  onSignIn,
  isShared,
  isWorking,
}: HomeProps) {
  // A stored view from another version must not break the page.
  const view: CollectionView = collectionView === 'grid' || collectionView === 'closet' ? collectionView : 'list'
  // A restored Listen later tab waits on Active until album picks are known to be on.
  const tab: MixesTab = requestedTab === 'listen-later' && !(albumPicks && shelf) ? 'active' : requestedTab
  const archived = tab === 'archived'
  const onShelf = tab === 'listen-later' && shelf
  const tabs: { id: MixesTab; label: string }[] = [{ id: 'active', label: 'Active' }, { id: 'archived', label: 'Archived' }]
  if (albumPicks) tabs.push({ id: 'listen-later', label: 'Listen later' })
  // Shared rows belong with the active mixes only: they are never archived.
  const items: MixesItem[] = tab === 'active' ? mergeSharedRows(sessions, sharedRows) : sessions.map((session) => ({ kind: 'session', session }))
  const count = items.length
  const ownIds = items.flatMap((entry) => entry.kind === 'session' ? [entry.session.id] : [])
  // Select mode: List and Grid only, never the shelf or the closet.
  const [selecting, setSelecting] = useState(false)
  const [picked, setPicked] = useState<string[]>([])
  const anchor = useRef<string | null>(null)
  const [confirm, setConfirm] = useState<'delete' | 'sign-in' | null>(null)
  const [deleting, setDeleting] = useState(false)
  const [deleteError, setDeleteError] = useState('')
  const [archiving, setArchiving] = useState(false)
  // Mixes that left the list (deleted, archived, refreshed away) leave the selection too.
  const selected = picked.filter((id) => ownIds.includes(id))
  const canSelect = !onShelf && view !== 'closet'
  const exitSelect = () => {
    setSelecting(false)
    setPicked([])
    anchor.current = null
    setConfirm(null)
    setDeleteError('')
  }
  // Leaving the tab or switching to the closet ends select mode.
  useEffect(() => { exitSelect() }, [tab, view])
  useEffect(() => {
    if (!selecting || confirm) return
    const escape = (event: KeyboardEvent) => {
      // An open row menu takes the Escape first.
      // An open row menu or modal (Tape settings) takes the Escape first.
      if (event.key !== 'Escape' || document.querySelector('.mixes-panel .wc-session-menu, [role="dialog"], [role="alertdialog"]')) return
      exitSelect()
    }
    document.addEventListener('keydown', escape)
    return () => document.removeEventListener('keydown', escape)
  }, [selecting, confirm])
  const toggle = (id: string, range: boolean) => {
    const from = anchor.current
    anchor.current = id
    setPicked((current) => {
      const now = current.filter((item) => ownIds.includes(item))
      if (range && from && from !== id && ownIds.includes(from)) {
        const [a, b] = [ownIds.indexOf(from), ownIds.indexOf(id)].sort((x, y) => x - y)
        const span = new Set([...now, ...ownIds.slice(a, b + 1)])
        return ownIds.filter((item) => span.has(item))
      }
      return now.includes(id) ? now.filter((item) => item !== id) : ownIds.filter((item) => item === id || now.includes(item))
    })
  }
  const setStatus = onArchiveMany ?? (async (ids: string[], status: 'archived' | 'active') => {
    const results = await Promise.allSettled(ids.map((id) => (status === 'archived' ? onArchive : onRestore)?.(id)))
    return ids.filter((_, index) => results[index].status === 'rejected')
  })
  async function archiveSelected() {
    if (archiving || !selected.length) return
    setArchiving(true)
    try {
      const failed = await setStatus(selected, archived ? 'active' : 'archived')
      if (failed.length) setPicked(failed)
      else exitSelect()
    } catch {
      // The caller says what failed; the selection stays for a retry.
    } finally {
      setArchiving(false)
    }
  }
  function askDelete() {
    if (!selected.length) return
    setDeleteError('')
    setConfirm(anonymous ? 'sign-in' : 'delete')
  }
  async function deleteSelected() {
    if (deleting) return
    setDeleting(true)
    setDeleteError('')
    try {
      const result = await (onDeleteMany ?? (async () => 'deleted' as const))(selected)
      if (result === 'sign_in_required') setConfirm('sign-in')
      else exitSelect()
    } catch {
      setDeleteError('Couldn’t delete. Try again.')
    } finally {
      setDeleting(false)
    }
  }
  const deleteLines = [
    'They’re gone for good, with their chats and versions. This can’t be undone.',
    ...(isShared && selected.some(isShared) ? ['Their share links will stop working.'] : []),
    ...(isWorking && selected.some(isWorking) ? ['The one being made will stop.'] : []),
  ]
  const item = (entry: MixesItem, layout: 'row' | 'tile') => entry.kind === 'session' ? row(entry.session, layout) : (
    <SharedRow key={`shared:${entry.row.token}`} layout={layout} row={entry.row} onOpen={() => onOpenShared?.(entry.row.token)}
      onRemove={() => onRemoveShared?.(entry.row.token) ?? Promise.resolve()} dimmed={selecting} />
  )
  // The closet draws a shared mix as a tape like any other.
  const closetTapes: DjSession[] = items.map((entry) => entry.kind === 'session' ? entry.session : {
    id: `shared:${entry.row.token}`, title: entry.row.title, caseColor: entry.row.caseColor, durationLabel: durationLabel(entry.row.durationMs),
    status: 'active', queueVersion: 0, notPersonal: false, updatedAt: entry.row.savedAt, ageLabel: '', trackCount: entry.row.trackCount, kind: 'mix',
  })
  const openTape = (id: string) => id.startsWith('shared:') ? onOpenShared?.(id.slice('shared:'.length)) : onOpenSession(id)
  const row = (session: DjSession, layout: 'row' | 'tile') => (
    <SessionRow showTape layout={layout} key={session.id} session={session} onOpen={() => onOpenSession(session.id)}
      onColor={onColor ? (color) => onColor(session.id, color) : undefined}
      onRename={(title) => onRename?.(session.id, title) ?? Promise.resolve()}
      onArchive={() => onArchive?.(session.id) ?? Promise.resolve()}
      onRestore={() => onRestore?.(session.id) ?? Promise.resolve()}
      select={selecting ? { checked: selected.includes(session.id), fading: deleting && selected.includes(session.id), onToggle: (range) => toggle(session.id, range) } : undefined} />
  )
  return (
    <main className="home-panel mixes-panel">
      {player}
      <header className="home-header">
        <div>
          <h1>Mixes</h1>
          <p>{onShelf
            ? onShelf.entries === null && !onShelf.error ? 'Loading your shelf…' : shelfCountLine(onShelf.entries ?? [])
            : selecting ? `${selected.length} of ${count} selected`
            : loading && count === 0 ? 'Loading mixes…' : countLine(count, archived)}</p>
        </div>
        <NewTapeCompactButton onClick={onNewTape} />
      </header>

      {tab === 'active' && suggestions}
      <div className="mixes-toolbar">
        <Tabs label="Mix sections" current={tab} onSelect={(next) => onTab?.(next)} items={tabs} />
        {/* Albums have no closet or grid: the list is the only view, so the switch goes. */}
        {!onShelf && <div className="mixes-toolbar-end">
          {canSelect && (selecting || ownIds.length > 0) && <button type="button" className={`mixes-select${selecting ? ' is-on' : ''}`} onClick={() => selecting ? exitSelect() : setSelecting(true)}>{selecting ? 'Done' : 'Select'}</button>}
          <ViewSwitch value={view} onChange={onChangeCollectionView} />
        </div>}
      </div>

      {onShelf ? <div className="mixes-content"><Shelf {...onShelf} /></div> : <div className="mixes-content">
        {error && count > 0 && <div className="mix-refresh" role="alert"><span>Couldn’t refresh your mixes. Your mixes are still here.</span><button className="minimal-retry" onClick={onRetry}>Retry</button></div>}
        {loading && count === 0 ? <MixSkeletons view={view} /> : count === 0 ? <EmptyState kind={error ? 'error' : 'tape'} title={error ? 'Couldn’t load your mixes' : archived ? 'No archived mixes' : 'Your next moment starts here'} description={error ? 'Try again in a moment.' : archived ? 'Mixes you archive will appear here.' : 'Tell the DJ what you’re in the mood for.'} action={error ? { label: 'Try again', onClick: onRetry! } : archived ? undefined : { label: 'Make a mix', onClick: onNewTape }} />
          : view === 'list' ? <section className="tape-grid" aria-label="Tape list">{items.map((entry) => item(entry, 'row'))}</section>
          : view === 'grid' ? <section className="mix-grid" aria-label="Mix grid">{items.map((entry) => item(entry, 'tile'))}</section>
          : <TapeRack sessions={closetTapes} onOpenSession={openTape} />}
        {selecting && <div className="mixes-select-bar" role="toolbar" aria-label="Selected mixes">
          <span className="mixes-select-count" aria-live="polite">{selected.length} selected</span>
          <span className="mixes-select-sep" aria-hidden="true" />
          <button type="button" className="wc-text" disabled={!selected.length || archiving || deleting} onClick={() => void archiveSelected()}>{archived ? 'Unarchive' : 'Archive'}</button>
          <button type="button" className="wc-text wc-danger" disabled={!selected.length || archiving || deleting} onClick={askDelete}>Delete</button>
        </div>}
      </div>}
      {confirm === 'delete' && (
        <ControlModal title={selected.length === 1 ? 'Delete this mix?' : `Delete ${selected.length} mixes?`} alert onClose={() => { if (!deleting) setConfirm(null) }}>
          <p>{deleteLines.join(' ')}</p>
          {deleteError && <p className="wc-danger" role="alert">{deleteError}</p>}
          <div className="wc-actions">
            <button className="wc-text" disabled={deleting} onClick={() => setConfirm(null)}>Cancel</button>
            <button className="wc-text wc-danger" disabled={deleting} onClick={() => void deleteSelected()}>{selected.length === 1 ? 'Delete mix' : `Delete ${selected.length} mixes`}</button>
          </div>
        </ControlModal>
      )}
      {confirm === 'sign-in' && (
        <ControlModal title="Sign in to delete mixes" alert className="mixes-confirm" onClose={() => setConfirm(null)}>
          <p>Mixes made before you sign in can be archived, not deleted.</p>
          <div className="wc-actions">
            <button className="wc-text" onClick={() => setConfirm(null)}>Not now</button>
            <button className="wc-text" onClick={() => { setConfirm(null); onSignIn?.() }}>Sign in</button>
          </div>
        </ControlModal>
      )}
    </main>
  )
}

function Shelf({ entries, error, spotifyOnly, busy, pendingIds, onRetry, onFindAlbum, ...actions }: ShelfProps) {
  // Rows already on screen stay through a failed refresh; the error state is for an empty shelf.
  if (error && !entries?.length) return <EmptyState kind="error" title="Couldn’t load your shelf" description="Try again in a moment." action={{ label: 'Try again', onClick: onRetry }} />
  if (entries === null) return <MixSkeletons />
  if (entries.length === 0) return <EmptyState title="Nothing saved for later" description="Ask for an album, then choose Listen later to keep it here." action={{ label: 'Find an album', onClick: onFindAlbum }} />
  return <ListenLaterList entries={entries} spotifyOnly={spotifyOnly} busy={busy} pendingIds={pendingIds} {...actions} />
}

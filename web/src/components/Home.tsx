import { EmptyState, MixSkeletons } from './UiStates'
import { SessionRow } from './SessionControls'
import { TapeRack } from './TapeRack'
import { Tabs } from './Tabs'
import { ViewSwitch } from './ViewSwitch'
import type { CollectionView, DjSession, ListenLaterEntry } from '../domain'
import type { ReactNode } from 'react'
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
  collectionView: CollectionView
  onChangeCollectionView: (view: CollectionView) => void
  onOpenSession: (id: string) => void
  onNewTape: () => void
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
  loading = false, error, onRetry, onColor, player, suggestions, sessions, tab: requestedTab = 'active', onTab, albumPicks = false, shelf, onRename, onArchive, onRestore,
  collectionView,
  onChangeCollectionView,
  onOpenSession,
  onNewTape,
}: HomeProps) {
  // A stored view from another version must not break the page.
  const view: CollectionView = collectionView === 'grid' || collectionView === 'closet' ? collectionView : 'list'
  // A restored Listen later tab waits on Active until album picks are known to be on.
  const tab: MixesTab = requestedTab === 'listen-later' && !(albumPicks && shelf) ? 'active' : requestedTab
  const archived = tab === 'archived'
  const onShelf = tab === 'listen-later' && shelf
  const tabs: { id: MixesTab; label: string }[] = [{ id: 'active', label: 'Active' }, { id: 'archived', label: 'Archived' }]
  if (albumPicks) tabs.push({ id: 'listen-later', label: 'Listen later' })
  const row = (session: DjSession, layout: 'row' | 'tile') => (
    <SessionRow showTape layout={layout} key={session.id} session={session} onOpen={() => onOpenSession(session.id)}
      onColor={onColor ? (color) => onColor(session.id, color) : undefined}
      onRename={(title) => onRename?.(session.id, title) ?? Promise.resolve()}
      onArchive={() => onArchive?.(session.id) ?? Promise.resolve()}
      onRestore={() => onRestore?.(session.id) ?? Promise.resolve()} />
  )
  return (
    <main className="home-panel mixes-panel">
      {player}
      <header className="home-header">
        <div>
          <h1>Mixes</h1>
          <p>{onShelf
            ? onShelf.entries === null && !onShelf.error ? 'Loading your shelf…' : shelfCountLine(onShelf.entries ?? [])
            : loading && sessions.length === 0 ? 'Loading mixes…' : countLine(sessions.length, archived)}</p>
        </div>
        <NewTapeCompactButton onClick={onNewTape} />
      </header>

      {tab === 'active' && suggestions}
      <div className="mixes-toolbar">
        <Tabs label="Mix sections" current={tab} onSelect={(next) => onTab?.(next)} items={tabs} />
        {/* Albums have no closet or grid: the list is the only view, so the switch goes. */}
        {!onShelf && <ViewSwitch value={view} onChange={onChangeCollectionView} />}
      </div>

      {onShelf ? <div className="mixes-content"><Shelf {...onShelf} /></div> : <div className="mixes-content">
        {error && sessions.length > 0 && <div className="mix-refresh" role="alert"><span>Couldn’t refresh your mixes. Your mixes are still here.</span><button className="minimal-retry" onClick={onRetry}>Retry</button></div>}
        {loading && sessions.length === 0 ? <MixSkeletons view={view} /> : sessions.length === 0 ? <EmptyState kind={error ? 'error' : 'tape'} title={error ? 'Couldn’t load your mixes' : archived ? 'No archived mixes' : 'Your next moment starts here'} description={error ? 'Try again in a moment.' : archived ? 'Mixes you archive will appear here.' : 'Tell the DJ what you’re in the mood for.'} action={error ? { label: 'Try again', onClick: onRetry! } : archived ? undefined : { label: 'Make a mix', onClick: onNewTape }} />
          : view === 'list' ? <section className="tape-grid" aria-label="Tape list">{sessions.map((session) => row(session, 'row'))}</section>
          : view === 'grid' ? <section className="mix-grid" aria-label="Mix grid">{sessions.map((session) => row(session, 'tile'))}</section>
          : <TapeRack sessions={sessions} onOpenSession={onOpenSession} />}
      </div>}
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

import { useState } from 'react'
import { HomeDashboard } from './components/HomeDashboard'
import { Home } from './components/Home'
import { Sidebar } from './components/Sidebar'
import { SaveDialog, Toast } from './components/Overlays'
import { EmptyState } from './components/UiStates'
import { ControlModal } from './components/ControlModal'
import { TapeSettings } from './components/TapeSettings'
import { AppleMusicMark, SpotifyMark } from './components/ProviderMarks'
import { demoAlbumMessages, demoAlbumPick, demoAlbumRefinedPick, demoAlbumRunnersUp, demoMessages, demoQueue, demoSessions } from './data/demo'
import { AlbumPanel } from './components/AlbumPanel'
import { toAlbumPick } from './api/mappers'
import { useMediaQuery } from './lib/use-media-query'
import { Conversation } from './components/Conversation'
import { PlaylistAttachment } from './components/PlaylistAttachment'
import { QueuePanel } from './components/QueuePanel'
import { tapeColors } from './data/tape-colors'
import type { AlbumPickState, CollectionView, DjSession } from './domain'
import type { ApiPlaylistSummary, MixtapeApi } from './api/client'
import { PlaylistBrowser } from './components/PlaylistBrowser'
import { Tabs } from './components/Tabs'
import './components/web-controls.css'
import './components/your-music.css'
import { FirstRun } from './components/first-run/FirstRun'
import { KeepSheet } from './components/first-run/KeepSheet'
import { BackButton } from './components/first-run/FirstRunPage'
import { SignInPage } from './components/AuthGate'
import { createFirstRunServices } from './components/first-run/services'
import type { MusicKitClient } from './musickit/client'

const previewPlaylist: ApiPlaylistSummary = { id: 'preview', name: '“just a girl”', source: 'spotify_export', kind: 'user', origin: 'unknown', curatorName: null, artworkUrlTemplate: null, artworkBgColor: null, artworkWidth: null, artworkHeight: null, entryCount: 14, knownDurationMs: null, durationComplete: false, lastModifiedAt: null, syncedAt: '2026-09-18T12:00:00Z', inLibrary: true, capability: 'copy_only' }
const previewEntries = ['Present Tense', 'If You Say the Word', 'The Girl Is Mine', 'Let My Baby Stay', 'Do What You Gotta Do', 'Home recording'].map((title, position) => ({ id: String(position), position, trackId: null, appleCatalogId: null, spotifyId: position === 5 ? null : '4uLU6hMCjMI75M1A2tKUQC', title, artist: 'Synthetic artist', album: null, durationMs: null, artworkUrlTemplate: null, artworkWidth: null, artworkHeight: null, artworkBgColor: null, resolved: false }))
const previewLibraryApi = (loading: boolean) => ({
  listPlaylists: async () => ({ playlists: [previewPlaylist], nextCursor: null, total: 1 }),
  getPlaylist: () => loading ? new Promise(() => {}) : Promise.resolve({ playlist: previewPlaylist, entries: previewEntries, nextEntryCursor: null }),
  confirmPlaylistTaste: async () => ({ ok: true }),
}) as unknown as MixtapeApi
const previewLibraryApis = { library: previewLibraryApi(false), 'library-loading': previewLibraryApi(true) }
// Two picks the listener does not own yet; the second has a long artist name so the mark's truncation shows.
const previewQueue = demoQueue.map((track, index) =>
  index === 1 ? { ...track, newToYou: true }
  : index === 3 ? { ...track, artist: 'Ilse Varga and the Night Shift Choir Orchestra', newToYou: true }
  : track)

// Synthetic first-run services: seeds and the first mix resolve, a sync fails at once (no API here).
const previewFirstRunServices = () => createFirstRunServices({
  api: { createSession: async () => ({ session: { id: 'preview' } }), putArtistSeeds: async () => ({ seeds: [] }), postFunnelEvent: async () => ({ ok: true }) } as unknown as MixtapeApi,
  musicKit: { connect: async () => { throw new Error('preview') } } as unknown as MusicKitClient,
  ensureSession: async () => undefined,
})

// Board W3 (first pick, runners-up folded) and W4 (refined, Spotify-only, saved, runners-up open).
const previewAlbumStates: Record<'album' | 'album-refined', AlbumPickState> = {
  album: { version: 1, pick: toAlbumPick(demoAlbumPick), runnersUp: demoAlbumRunnersUp.map(toAlbumPick), passed: [] },
  'album-refined': {
    version: 2,
    pick: { ...toAlbumPick(demoAlbumRefinedPick), savedForLater: true },
    runnersUp: demoAlbumRunnersUp.map((album) => toAlbumPick({ ...album, version: 2 })),
    passed: [toAlbumPick(demoAlbumPick)],
  },
}

/** The album states with local saved toggles, so the founder can click around. */
function AlbumPreview({ state, session }: { state: 'album' | 'album-refined'; session: DjSession }) {
  const [albums, setAlbums] = useState(previewAlbumStates[state])
  const refined = state === 'album-refined'
  const flip = (id: string) => setAlbums((current) => {
    const toggle = <T extends { id: string; savedForLater: boolean }>(album: T) => (album.id === id ? { ...album, savedForLater: !album.savedForLater } : album)
    return { ...current, pick: current.pick && toggle(current.pick), runnersUp: current.runnersUp.map(toggle), passed: current.passed.map(toggle) }
  })
  const albumSession = { ...session, kind: 'album' as const, title: 'Train home', queueVersion: albums.version, trackCount: 0 }
  // As the app: below the shell's third column the panel folds into the conversation (W5).
  const narrow = useMediaQuery('(max-width: 1020px)')
  const panel = (inline: boolean) => <AlbumPanel key={state} state={albums} spotifyOnly={refined} defaultExpanded={refined} onPlay={() => {}} onToggleSaved={(album) => flip(album.id)} onPick={() => {}} inline={inline} />
  return <>
    <Conversation kind="album" session={albumSession} messages={refined ? demoAlbumMessages : demoAlbumMessages.slice(0, 2)} passed={albums.passed} onGoBack={() => {}} thinking={false} onSend={() => {}} attachment={<PlaylistAttachment api={previewLibraryApis.library} value={null} onSelect={async () => {}} onSessionExpired={() => {}} />} inlinePanel={narrow ? panel(true) : undefined} inlinePanelVersion={albums.version} />
    {narrow ? null : panel(false)}
  </>
}

export default function UiPolishPreview() {
  const [state, setState] = useState('populated')
  const [sessions, setSessions] = useState(demoSessions.slice(0, 4).map((session, index) => ({ ...session, caseColor: tapeColors[index * 9][1] as string })))
  const [collectionView, setCollectionView] = useState<CollectionView>('list')
  async function color(id: string, caseColor: string) { setSessions(current => current.map(s => s.id === id ? { ...s, caseColor } : s)) }
  const close = () => setState('populated')
  const options = ['home', 'home-loading', 'home-empty', 'home-error', 'populated', 'loading', 'empty', 'archived', 'load-error', 'refresh-error', 'settings', 'success', 'error', 'info', 'playlist', 'preference', 'memory', 'sources', 'library', 'library-loading', 'conversation', 'conversation-blank', 'album', 'album-refined', 'first-run', 'keep-sheet', 'sign-in-keep', 'sign-in-cap', 'merge-notice']
  return <>
    <div style={{ position: 'fixed', right: 12, top: 8, zIndex: 200, display: 'flex', gap: 8, alignItems: 'center', background: '#f7f4f8', color: '#1c1a1e', padding: 8, borderRadius: 8, fontSize: 12 }}>
      <label htmlFor="ui-preview-state">UI preview · synthetic data</label><select id="ui-preview-state" value={state} onChange={e => setState(e.target.value)}>{options.map(option => <option key={option}>{option}</option>)}</select>
    </div>
    <div className={state.startsWith('conversation') || state.startsWith('album') ? 'app-shell' : 'app-shell app-shell--home'}>
      <Sidebar activeView={state.startsWith('home') ? 'home' : state === 'sources' ? 'music' : 'mixes'} onOpenHome={() => setState('home')} onOpenMusic={() => setState('sources')} onOpenMixes={close} onOpenSettings={() => setState('preference')} />
      {state.startsWith('conversation') ? <>
        <Conversation session={sessions[0]} messages={state === 'conversation' ? demoMessages : []} thinking={false} onSend={() => {}} onOpenQueue={() => {}} attachment={<PlaylistAttachment api={previewLibraryApis.library} value={null} onSelect={async () => {}} onSessionExpired={() => {}} />} />
        <QueuePanel key={state} session={sessions[0]} tracks={state === 'conversation' ? previewQueue : []} playing={false} playbackBusy={false} musicConnection="connected" open={false} onConnect={() => {}} onTogglePlay={() => {}} onSave={() => {}} onClose={() => {}} onPreviewTracks={() => {}} onCommitQueueOp={async () => {}} />
      </>
      : state === 'album' || state === 'album-refined' ? <AlbumPreview key={state} state={state} session={sessions[0]} />
      : state.startsWith('home') ? <HomeDashboard sessions={state === 'home' ? sessions : []} loading={state === 'home-loading'} error={state === 'home-error' ? 'Unavailable' : ''} busy={false} player={null} suggestions={state === 'home' ? <section className="routine-suggestions"><h2>For this moment</h2><div className="routine-card"><img className="routine-tape" src="/tape.svg" alt=""/><div className="routine-copy"><h3>A softer evening</h3><p>You often slow things down around this time.</p></div><div className="routine-actions"><button className="routine-primary">Make this mix</button><button>Not today</button></div></div></section> : null} onRetry={() => setState('home')} onOpenSession={close} onOpenMixes={close} albumPicks anonymous={false} onSubmit={async()=>{setState('populated')}} transcribe={async()=>({text:'A softer evening'})} onRename={async()=>{}} onArchive={async()=>{}} onColor={color}/> : state === 'memory' ? <main className="wc-view"><h1>What the DJ knows</h1><EmptyState kind="memory" title="No saved preferences yet" description="Tell the DJ what you would like it to remember." /></main>
      : state === 'library' || state === 'library-loading' ? <main className="ym-view"><header className="ym-header"><h1>Library</h1></header><Tabs label="Library sections" current="playlists" onSelect={close} items={[{ id: 'playlists', label: 'Playlists' }, { id: 'sources', label: 'Sources' }]} /><div className="ym-content"><PlaylistBrowser key={state} api={previewLibraryApis[state]} onInspire={close} onSources={close} onSessionExpired={close} /></div></main>
      : state === 'sources' ? <main className="ym-view"><header className="ym-header"><h1>Library</h1></header><div className="library-source-badges"><button className="library-source-badge"><AppleMusicMark />Apple Music<small>Connected</small></button><button className="library-source-badge"><SpotifyMark />Spotify<small>Imported</small></button></div><EmptyState title="No playlists yet" description="Playlists you bring from your music services will appear here." /></main>
      : <Home sessions={['loading','empty','archived','load-error'].includes(state) ? [] : sessions} archived={state === 'archived'} loading={state === 'loading'} error={state.endsWith('error') ? 'Couldn’t load' : undefined} onRetry={close} onArchived={value => setState(value ? 'archived' : 'populated')} onColor={color} onRename={async(id,title) => setSessions(current=>current.map(s=>s.id === id ? {...s,title}:s))} onArchive={async()=>setState('info')} onRestore={async()=>setState('success')} collectionView={collectionView} onChangeCollectionView={setCollectionView} onOpenSession={() => {}} onNewTape={()=>setState('playlist')} />}
    </div>
    {state === 'settings' && <TapeSettings session={sessions[0]} onColor={caseColor=>color(sessions[0].id,caseColor)} onClose={close} />}
    {['success','error','info'].includes(state) && <Toast tone={state as 'success'|'error'|'info'} message={state === 'success' ? 'Playlist created' : state === 'error' ? 'Couldn’t save. Try again.' : 'Mix archived'} action={state === 'info' ? { label: 'Undo', onClick:close }:undefined} />}
    {state === 'keep-sheet' && <KeepSheet onKeep={() => setState('sign-in-keep')} onNotNow={close} />}
    {(state === 'sign-in-keep' || state === 'sign-in-cap') && <div className="first-run fr-root fr-root--over"><div className="fr-sign-in"><BackButton onBack={close} className="fr-back--over" /><SignInPage variant={state === 'sign-in-cap' ? 'cap' : 'keep'} auth={{ signIn: async () => ({}) }} preferences={{ lastUsed: () => 'apple', begin: () => {}, promotePending: () => null, clearPending: () => {} }} lastUsed="apple" error="" /></div></div>}
    {state === 'merge-notice' && <Toast tone="success" message="Your mixes are in. This account already had a library, so we kept that one." />}
    {state === 'first-run' && <FirstRun services={previewFirstRunServices} signIn={{ auth: { signIn: async () => ({}) }, preferences: { lastUsed: () => null, begin: () => {}, promotePending: () => null, clearPending: () => {} }, lastUsed: null, error: '' }} onDone={close} />}
    {state === 'playlist' && <SaveDialog defaultName="Evening colours" newToYouCount={2} onSave={()=>setState('success')} onClose={close} />}
    {state === 'preference' && <ControlModal title="Forget this preference?" alert onClose={close}><p>Keep vocals in the background for dinner.</p><p>The DJ will stop using this note. You can’t undo this.</p><div className="wc-actions"><button className="wc-text" onClick={close}>Cancel</button><button className="wc-text wc-danger" onClick={()=>setState('success')}>Forget preference</button></div></ControlModal>}
  </>
}

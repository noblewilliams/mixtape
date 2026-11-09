import { useEffect, useMemo, useState } from 'react'
import { HomeDashboard } from './components/HomeDashboard'
import { Home } from './components/Home'
import { Sidebar } from './components/Sidebar'
import { SaveDialog, Toast } from './components/Overlays'
import { EmptyState } from './components/UiStates'
import { ControlModal } from './components/ControlModal'
import { TapeSettings } from './components/TapeSettings'
import { AppSettings, DeleteAccountDialog, type NameEdit } from './components/AppSettings'
import { PlaybackController } from './playback/controller'
import { AiConsentDialog } from './components/AiConsent'
import { AppleMusicMark, SpotifyMark } from './components/ProviderMarks'
import { demoAlbumMessages, demoAlbumPick, demoAlbumRefinedPick, demoAlbumRunnersUp, demoMessages, demoQueue, demoSessions, demoShelfPreviewEntries } from './data/demo'
import { AlbumPanel } from './components/AlbumPanel'
import { toAlbumPick, toListenLaterEntry } from './api/mappers'
import { placeOnShelf } from './components/ListenLaterList'
import type { MixesTab } from './components/Home'
import type { ModeSeed } from './components/HomeComposer'
import { useMediaQuery } from './lib/use-media-query'
import { Conversation } from './components/Conversation'
import { PlaylistAttachment } from './components/PlaylistAttachment'
import { QueuePanel } from './components/QueuePanel'
import { tapeColors } from './data/tape-colors'
import type { AlbumPickState, CollectionView, DjMessage, DjSession, ListenLaterEntry } from './domain'
import type { ApiPlaylistSummary, MixtapeApi, OnboardingResponse } from './api/client'
import type { MusicDoorInput } from './components/MusicDoor'
import type { MusicSyncRunState } from './sync/music-sync-run'
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
import { NamePage, type NamePageInitial } from './components/first-run/NamePage'
import { publicAsset } from './lib/public-asset'

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
  api: { createSession: async () => ({ session: { id: 'preview' } }), putArtistSeeds: async () => ({ seeds: [] }), postFunnelEvent: async () => ({ ok: true }), grantAiConsent: async () => ({ aiConsent: true }) } as unknown as MixtapeApi,
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

// Board W6 (the shelf) and W7 (empty); Remove and Mark listened act locally so the founder can click around.
const previewShelf: ListenLaterEntry[] = demoShelfPreviewEntries.map(toListenLaterEntry)
function ListenLaterPreview({ empty, sessions, onTab, onFindAlbum }: { empty: boolean; sessions: DjSession[]; onTab: (tab: MixesTab) => void; onFindAlbum: () => void }) {
  const [entries, setEntries] = useState(empty ? [] : previewShelf)
  return <Home sessions={sessions} tab="listen-later" onTab={onTab} albumPicks collectionView="list" onChangeCollectionView={() => {}} onOpenSession={() => {}} onNewTape={() => {}}
    shelf={{
      entries, spotifyOnly: false, onRetry: () => {}, onFindAlbum, onOpen: () => {}, onPlay: () => {},
      onMarkListened: (entry) => setEntries((current) => placeOnShelf(current, { ...entry, listenedAt: new Date().toISOString() })),
      onRemove: (entry) => setEntries((current) => current.filter((item) => item.id !== entry.id)),
    }} />
}

// Profile name board W-S1 (unnamed), W-S2 (named), W-S3 (editing), W-S5 (failed). Saves resolve
// after a beat and update the shown name; the failed state keeps failing so Retry shows Saving then the error again.
const previewSettingsApi = {
  getSuggestions: async () => ({ enabled: true, suggestion: null, dismissed: false }),
  saveSuggestionPreference: async (enabled: boolean) => ({ enabled }),
  playbackPreferences: async () => ({ enabled: true, revision: 1 }),
} as unknown as MixtapeApi
type SettingsPreviewState = 'settings-named' | 'settings-unnamed' | 'settings-editing' | 'settings-failed'
const previewNameEdits: Partial<Record<SettingsPreviewState, NameEdit>> = {
  'settings-editing': { draft: 'Ada Okafor' },
  'settings-failed': { draft: 'Ada Okafor', failed: true },
}
function SettingsPreview({ state, onMemories }: { state: SettingsPreviewState; onMemories: () => void }) {
  const playback = useMemo(() => new PlaybackController(previewSettingsApi, {} as MusicKitClient, 'ui-preview'), [])
  useEffect(() => { void playback.initialize(); return () => playback.dispose() }, [playback])
  const [name, setName] = useState(state === 'settings-unnamed' ? '' : 'Ada Okafor')
  const saveName = (next: string) => new Promise<void>((resolve, reject) => setTimeout(() => {
    if (state === 'settings-failed') reject(new Error('preview'))
    else { setName(next); resolve() }
  }, 900))
  return <AppSettings api={previewSettingsApi} playback={playback} userName={name} signInMethod="apple" onAccount={() => {}} onMemories={onMemories} onSignOut={() => {}} onAccountDeleted={() => {}} saveName={saveName} initialNameEdit={previewNameEdits[state]} />
}

// Profile name board NW1 (empty), NW2 (typing), NW3 (saving), NW4 (failed). Continue resolves after a
// beat and closes the page; the failed state keeps failing so Retry shows Saving then the error again.
type NamePreviewState = 'name-page' | 'name-page-typing' | 'name-page-saving' | 'name-page-failed'
const previewNamePages: Partial<Record<NamePreviewState, NamePageInitial>> = {
  'name-page-typing': { draft: 'Ada Okafor' },
  'name-page-saving': { draft: 'Ada Okafor', saving: true },
  'name-page-failed': { draft: 'Ada Okafor', failed: true },
}
function NamePagePreview({ state, onDone }: { state: NamePreviewState; onDone: () => void }) {
  const saveName = () => new Promise<void>((resolve, reject) => setTimeout(() => {
    if (state === 'name-page-failed') reject(new Error('preview'))
    else resolve()
  }, 900))
  return <div className="first-run fr-root fr-root--over"><div className="fr-stage fr-stage--fade"><NamePage saveName={saveName} onSaved={onDone} onSkip={onDone} initial={previewNamePages[state]} /></div></div>
}

// Add your music board section 5 (W1 to W3) and the door's states on a catalog mix. Remake goes
// to the working state for a beat, then the mix is personal and the door and banner go.
type CatalogPreviewState = 'catalog' | 'catalog-spotify' | 'catalog-unknown' | 'catalog-syncing' | 'catalog-sync-failed' | 'catalog-spotify-waiting' | 'catalog-music-in' | 'catalog-history'
const previewBlankOnboarding: OnboardingResponse = { userId: 'ui-preview', sources: [], hasLibrary: false, chosenService: null, markedRequestedAt: null, interviewCompletedAt: null, importCompletedAt: null, interview: null, musicReady: false }
const previewCatalogMessages: DjMessage[] = [
  { id: 'catalog-1', role: 'user', content: 'Rainy commute over the bridge, Tems and Asake energy, nothing too loud', createdAt: '2026-11-09T08:00:00.000Z' },
  { id: 'catalog-2', role: 'dj', content: 'Fifteen for the bridge in the rain: Tems while it’s slow, Asake once the traffic moves. I don’t know your music yet, so these come from Mixtape’s catalog.', queueVersion: 1, createdAt: '2026-11-09T08:00:08.000Z' },
]
const previewCatalog: Record<CatalogPreviewState, { platform: MusicDoorInput['platform']; onboarding: OnboardingResponse; sync: MusicSyncRunState }> = {
  catalog: { platform: 'apple', onboarding: previewBlankOnboarding, sync: { kind: 'idle' } },
  'catalog-spotify': { platform: 'spotify', onboarding: previewBlankOnboarding, sync: { kind: 'idle' } },
  'catalog-unknown': { platform: null, onboarding: previewBlankOnboarding, sync: { kind: 'idle' } },
  'catalog-syncing': { platform: 'apple', onboarding: previewBlankOnboarding, sync: { kind: 'running', progress: { stage: 'uploading_library', completed: 42, total: 100 } } },
  'catalog-sync-failed': { platform: 'apple', onboarding: previewBlankOnboarding, sync: { kind: 'error', failure: 'connection' } },
  'catalog-spotify-waiting': { platform: 'spotify', onboarding: { ...previewBlankOnboarding, chosenService: 'spotify', markedRequestedAt: '2026-11-08T09:00:00.000Z' }, sync: { kind: 'idle' } },
  'catalog-music-in': { platform: 'spotify', onboarding: { ...previewBlankOnboarding, chosenService: 'spotify', musicReady: true }, sync: { kind: 'idle' } },
  'catalog-history': { platform: 'spotify', onboarding: { ...previewBlankOnboarding, chosenService: 'spotify', hasLibrary: true }, sync: { kind: 'idle' } },
}
function CatalogPreview({ state, session, onBack }: { state: CatalogPreviewState; session: DjSession; onBack: () => void }) {
  const preset = previewCatalog[state]
  const syncRun = useMemo(() => ({ getState: () => preset.sync, subscribe: () => () => {} }), [preset])
  const narrow = useMediaQuery('(max-width: 1020px)')
  const [open, setOpen] = useState(false)
  const [thinking, setThinking] = useState(false)
  const [messages, setMessages] = useState(previewCatalogMessages)
  const [notPersonal, setNotPersonal] = useState(state !== 'catalog-history')
  const remake = () => {
    setOpen(false)
    setThinking(true)
    setMessages((current) => [...current, { id: `remake-${current.length}`, role: 'user', content: 'Remake this with my music', createdAt: new Date().toISOString() }])
    setTimeout(() => {
      setMessages((current) => [...current, { id: `remade-${current.length}`, role: 'dj', content: 'Remade from your music: twelve of the fifteen are yours now.', queueVersion: 2, createdAt: new Date().toISOString() }])
      setThinking(false)
      setNotPersonal(false)
    }, 1600)
  }
  const catalogSession = { ...session, title: 'Rain on Third Mainland', notPersonal, queueVersion: notPersonal ? 1 : 2 }
  const musicDoor: MusicDoorInput = { onboarding: preset.onboarding, syncRun, platform: preset.platform, onAddMusic: () => {}, onRemake: remake, busy: thinking, pending: thinking }
  return <>
    <Conversation session={catalogSession} messages={messages} thinking={thinking} onSend={() => {}} onOpenQueue={() => setOpen(true)} onBack={onBack} musicDoor={musicDoor} musicDoorCovered={narrow && open} onAddHistory={state === 'catalog-history' ? () => {} : undefined} attachment={<PlaylistAttachment api={previewLibraryApis.library} value={null} onSelect={async () => {}} onSessionExpired={() => {}} />} />
    <QueuePanel session={catalogSession} tracks={previewQueue} playing={false} playbackBusy={false} musicConnection={preset.platform === 'spotify' ? 'disconnected' : 'connected'} spotifyOnly={preset.platform === 'spotify'} open={open} onConnect={() => {}} onTogglePlay={() => {}} onSave={() => {}} onClose={() => setOpen(false)} onPreviewTracks={() => {}} onCommitQueueOp={async () => {}} narrow={narrow} musicDoor={musicDoor} />
  </>
}

function previewConsent() {
  let tries = 0
  return () => new Promise<void>((resolve, reject) => setTimeout(() => (tries++ === 0 ? reject(new Error('preview')) : resolve()), 1000))
}

export default function UiPolishPreview() {
  const [state, setState] = useState('populated')
  const [sessions, setSessions] = useState(demoSessions.slice(0, 4).map((session, index) => ({ ...session, caseColor: tapeColors[index * 9][1] as string })))
  const [collectionView, setCollectionView] = useState<CollectionView>('list')
  const [modeSeed, setModeSeed] = useState<ModeSeed | null>(null)
  const [consentAgree] = useState(previewConsent)
  const openTab = (tab: MixesTab) => setState(tab === 'archived' ? 'archived' : tab === 'listen-later' ? 'listen-later' : 'populated')
  async function color(id: string, caseColor: string) { setSessions(current => current.map(s => s.id === id ? { ...s, caseColor } : s)) }
  const close = () => setState('populated')
  const options = ['home', 'home-loading', 'home-empty', 'home-error', 'populated', 'loading', 'empty', 'archived', 'load-error', 'refresh-error', 'settings', 'success', 'error', 'info', 'playlist', 'preference', 'memory', 'sources', 'library', 'library-loading', 'conversation', 'conversation-blank', 'conversation-spotify', 'conversation-ask', 'catalog', 'catalog-spotify', 'catalog-unknown', 'catalog-syncing', 'catalog-sync-failed', 'catalog-spotify-waiting', 'catalog-music-in', 'catalog-history', 'album', 'album-refined', 'listen-later', 'listen-later-empty', 'first-run', 'keep-sheet', 'sign-in-keep', 'sign-in-cap', 'merge-notice', 'delete-account', 'settings-named', 'settings-unnamed', 'settings-editing', 'settings-failed', 'name-page', 'name-page-typing', 'name-page-saving', 'name-page-failed', 'first-run-consent', 'ai-consent']
  return <>
    <div style={{ position: 'fixed', right: 12, top: 8, zIndex: 200, display: 'flex', gap: 8, alignItems: 'center', background: '#f7f4f8', color: '#1c1a1e', padding: 8, borderRadius: 8, fontSize: 12 }}>
      <label htmlFor="ui-preview-state">UI preview · synthetic data</label><select id="ui-preview-state" value={state} onChange={e => setState(e.target.value)}>{options.map(option => <option key={option}>{option}</option>)}</select>
    </div>
    <div className={state.startsWith('conversation') || state.startsWith('album') || state.startsWith('catalog') ? 'app-shell' : 'app-shell app-shell--home'}>
      <Sidebar activeView={state.startsWith('home') ? 'home' : state === 'sources' ? 'music' : state.startsWith('settings-') ? 'settings' : 'mixes'} onOpenHome={() => setState('home')} onOpenMusic={() => setState('sources')} onOpenMixes={close} onOpenSettings={() => setState('preference')} />
      {state.startsWith('conversation') ? <>
        <Conversation session={sessions[0]} messages={state === 'conversation-blank' ? [] : demoMessages} thinking={false} onSend={() => {}} onOpenQueue={() => {}} onBack={close} attachment={<PlaylistAttachment api={previewLibraryApis.library} value={null} onSelect={async () => {}} onSessionExpired={() => {}} />} />
        <QueuePanel key={state} session={sessions[0]} tracks={state === 'conversation-blank' ? [] : state === 'conversation-spotify' ? previewQueue.map((track) => ({ ...track, spotifyId: null })) : previewQueue} playing={false} playbackBusy={false} musicConnection={state === 'conversation-spotify' || state === 'conversation-ask' ? 'disconnected' : 'connected'} spotifyOnly={state === 'conversation-spotify'} askService={state === 'conversation-ask'} open={false} onConnect={() => {}} onTogglePlay={() => {}} onSave={() => {}} onClose={() => {}} onPreviewTracks={() => {}} onCommitQueueOp={async () => {}} />
      </>
      : state.startsWith('catalog') ? <CatalogPreview key={state} state={state as CatalogPreviewState} session={sessions[0]} onBack={close} />
      : state.startsWith('settings-') ? <SettingsPreview key={state} state={state as SettingsPreviewState} onMemories={() => setState('memory')} />
      : state === 'album' || state === 'album-refined' ? <AlbumPreview key={state} state={state} session={sessions[0]} />
      : state === 'listen-later' || state === 'listen-later-empty' ? <ListenLaterPreview key={state} empty={state === 'listen-later-empty'} sessions={sessions} onTab={openTab} onFindAlbum={() => { setModeSeed({ kind: 'album', id: Date.now() }); setState('home') }} />
      : state.startsWith('home') ? <HomeDashboard sessions={state === 'home' ? sessions : []} loading={state === 'home-loading'} error={state === 'home-error' ? 'Unavailable' : ''} busy={false} player={null} suggestions={state === 'home' ? <section className="routine-suggestions"><h2>For this moment</h2><div className="routine-card"><img className="routine-tape" src={publicAsset('tape.svg')} alt=""/><div className="routine-copy"><h3>A softer evening</h3><p>You often slow things down around this time.</p></div><div className="routine-actions"><button className="routine-primary">Make this mix</button><button>Not today</button></div></div></section> : null} onRetry={() => setState('home')} onOpenSession={close} onOpenMixes={close} albumPicks anonymous={false} onSubmit={async()=>{setState('populated')}} transcribe={async()=>({text:'A softer evening'})} modeSeed={modeSeed} onRename={async()=>{}} onArchive={async()=>{}} onColor={color}/> : state === 'memory' ? <main className="wc-view"><h1>What the DJ knows</h1><EmptyState kind="memory" title="No saved preferences yet" description="Tell the DJ what you would like it to remember." /></main>
      : state === 'library' || state === 'library-loading' ? <main className="ym-view"><header className="ym-header"><h1>Library</h1></header><Tabs label="Library sections" current="playlists" onSelect={close} items={[{ id: 'playlists', label: 'Playlists' }, { id: 'sources', label: 'Sources' }]} /><div className="ym-content"><PlaylistBrowser key={state} api={previewLibraryApis[state]} onInspire={close} onSources={close} onSessionExpired={close} /></div></main>
      : state === 'sources' ? <main className="ym-view"><header className="ym-header"><h1>Library</h1></header><div className="library-source-badges"><button className="library-source-badge"><AppleMusicMark />Apple Music<small>Connected</small></button><button className="library-source-badge"><SpotifyMark />Spotify<small>Imported</small></button></div><EmptyState title="No playlists yet" description="Playlists you bring from your music services will appear here." /></main>
      : <Home sessions={['loading','empty','archived','load-error'].includes(state) ? [] : sessions} tab={state === 'archived' ? 'archived' : 'active'} albumPicks loading={state === 'loading'} error={state.endsWith('error') ? 'Couldn’t load' : undefined} onRetry={close} onTab={openTab} onColor={color} onRename={async(id,title) => setSessions(current=>current.map(s=>s.id === id ? {...s,title}:s))} onArchive={async()=>setState('info')} onRestore={async()=>setState('success')} collectionView={collectionView} onChangeCollectionView={setCollectionView} onOpenSession={() => {}} onNewTape={()=>setState('playlist')} />}
    </div>
    {state === 'settings' && <TapeSettings session={sessions[0]} onColor={caseColor=>color(sessions[0].id,caseColor)} onClose={close} />}
    {['success','error','info'].includes(state) && <Toast tone={state as 'success'|'error'|'info'} message={state === 'success' ? 'Playlist created' : state === 'error' ? 'Couldn’t save. Try again.' : 'Mix archived'} action={state === 'info' ? { label: 'Undo', onClick:close }:undefined} />}
    {state === 'keep-sheet' && <KeepSheet onKeep={() => setState('sign-in-keep')} onNotNow={close} />}
    {(state === 'sign-in-keep' || state === 'sign-in-cap') && <div className="first-run fr-root fr-root--over"><div className="fr-sign-in"><BackButton onBack={close} className="fr-back--over" /><SignInPage variant={state === 'sign-in-cap' ? 'cap' : 'keep'} auth={{ signIn: async () => ({}) }} preferences={{ lastUsed: () => 'apple', begin: () => {}, promotePending: () => null, clearPending: () => {}, forget: () => {} }} lastUsed="apple" error="" onSkip={state === 'sign-in-keep' ? close : undefined} /></div></div>}
    {state === 'merge-notice' && <Toast tone="success" message="Your mixes are in. This account already had a library, so we kept that one." />}
    {state.startsWith('name-page') && <NamePagePreview key={state} state={state as NamePreviewState} onDone={close} />}
    {/* The consent dialog: over the first run's prompt page, and over the app. The first Agree fails after a beat (busy, then the inline error); the next one goes through. */}
    {state === 'first-run-consent' && <><FirstRun services={previewFirstRunServices} onDone={close} /><AiConsentDialog onAgree={async () => { await consentAgree(); setState('first-run') }} onNotNow={() => setState('first-run')} /></>}
    {state === 'ai-consent' && <AiConsentDialog onAgree={async () => { await consentAgree(); close() }} onNotNow={close} />}
    {state === 'first-run' && <FirstRun services={previewFirstRunServices} signIn={{ auth: { signIn: async () => ({}) }, preferences: { lastUsed: () => null, begin: () => {}, promotePending: () => null, clearPending: () => {}, forget: () => {} }, lastUsed: null, error: '' }} onDone={close} />}
    {state === 'playlist' && <SaveDialog defaultName="Evening colours" newToYouCount={2} onSave={()=>setState('success')} onClose={close} />}
    {/* Confirming fails after a beat, so both the in-flight and failure states show. */}
    {state === 'delete-account' && <DeleteAccountDialog deleteAccount={() => new Promise((_, reject) => setTimeout(() => reject(new Error('preview')), 1200))} onDeleted={close} onClose={close} />}
    {state === 'preference' && <ControlModal title="Forget this preference?" alert onClose={close}><p>Keep vocals in the background for dinner.</p><p>The DJ will stop using this note. You can’t undo this.</p><div className="wc-actions"><button className="wc-text" onClick={close}>Cancel</button><button className="wc-text wc-danger" onClick={()=>setState('success')}>Forget preference</button></div></ControlModal>}
  </>
}

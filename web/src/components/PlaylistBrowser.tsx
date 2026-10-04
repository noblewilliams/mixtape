import { useRestorableState, useWorkspaceRestoring } from '../lib/workspace-restore'
import { PlaylistTasteControls } from './PlaylistTasteControls'
import { useEffect, useRef, useState } from 'react'
import { ApiError, type ApiPlaylistSummary, type MixtapeApi } from '../api/client'
import { MusicIcon } from './Icons'

const sourceLabel = (source: ApiPlaylistSummary['source']) =>
  source === 'spotify_export' ? 'Spotify' : 'Apple Music'
export const musicDate = (date: string | null) =>
  date
    ? new Date(date).toLocaleDateString(undefined, { day: 'numeric', month: 'short', year: 'numeric' })
    : null
const duration = (ms: number) =>
  `${Math.floor(ms / 60_000)}:${String(Math.floor(ms / 1000) % 60).padStart(2, '0')}`
function playlistMeta(playlist: ApiPlaylistSummary) {
  const minutes =
    playlist.durationComplete && playlist.knownDurationMs !== null
      ? ` · ${Math.round(playlist.knownDurationMs / 60_000)} min`
      : ''
  return `${playlist.entryCount.toLocaleString()} tracks${minutes}`
}

function PlaylistCover({ playlist }: { playlist: ApiPlaylistSummary }) {
  const [failed, setFailed] = useState(false)
  const template = playlist.artworkUrlTemplate
  const url = template?.startsWith('https://')
    ? template.replaceAll('{w}', '500').replaceAll('{h}', '500').replaceAll('{f}', 'jpg')
    : null
  return (
    <span className={`ym-cover ${!url || failed ? 'ym-cover--blank' : ''}`}>
      {url && !failed ? (
        <img src={url} alt="" loading="lazy" onError={() => setFailed(true)} />
      ) : (
        <MusicIcon />
      )}
    </span>
  )
}

export function MusicEmpty({
  title,
  children,
  action,
  onAction,
}: {
  title: string
  children: React.ReactNode
  action: string
  onAction: () => void
}) {
  return (
    <section className="ym-empty">
      <img className="music-empty-art" src={title.startsWith('Couldn’t') ? '/ui/connection-object.svg' : '/tape.svg'} alt="" />
      <h2>{title}</h2>
      <p>{children}</p>
      <button className={title.startsWith('Couldn’t') ? 'minimal-retry' : 'btn primary'} onClick={onAction}>
        {action}
      </button>
    </section>
  )
}

// Mirrors the loaded track rows so nothing jumps when data lands.
function DetailSkeleton({ playlist }: { playlist: ApiPlaylistSummary }) {
  const spotify = playlist.source === 'spotify_export'
  return (
    <div role="status" aria-label="Loading tracks" aria-busy="true">
      <ol className="ym-tracklist" aria-hidden="true">
        {Array.from({ length: Math.min(playlist.entryCount, 12) }, (_, i) => (
          <li className="ym-track" key={i}>
            <span className="ym-position">{i + 1}</span>
            <div>
              <span className="ym-bone" style={{ width: `${[38, 52, 30, 44][i % 4]}%` }} />
              <span className="ym-bone" style={{ width: `${[18, 14, 22, 16][i % 4]}%` }} />
            </div>
            <span className={spotify ? 'ym-bone ym-bone--action' : 'ym-bone ym-duration'} />
          </li>
        ))}
      </ol>
    </div>
  )
}

type Props = { onInspire?: (playlist: ApiPlaylistSummary) => void; api: MixtapeApi; onSources: () => void; onSessionExpired: () => void }
export function PlaylistBrowser({ onInspire, api, onSources, onSessionExpired }: Props) {
  const restoring = useWorkspaceRestoring()
  const [q, setQ] = useRestorableState('library.query', '')
  const [source, setSource] = useRestorableState<'' | ApiPlaylistSummary['source']>('library.source', '')
  const [data, setData] = useRestorableState<Awaited<ReturnType<MixtapeApi['listPlaylists']>> | null>('library.playlists', null)
  const [selected, setSelected] = useRestorableState<ApiPlaylistSummary | null>('library.selected', null)
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)
  const pending = useRef<AbortController | null>(null)
  const expired = useRef(onSessionExpired)
  expired.current = onSessionExpired

  useEffect(() => {
    if (restoring) return
    const controller = new AbortController()
    pending.current = controller
    setBusy(true)
    setFailed(false)
    // Debounce names, but always query the complete server-side collection.
    const timer = setTimeout(
      () => {
        void api
          .listPlaylists({ q: q.trim(), ...(source ? { source } : {}), limit: 30 }, controller.signal)
          .then((value) => {
            if (!controller.signal.aborted) setData(value)
          })
          .catch((error) => {
            if (!controller.signal.aborted) {
              setFailed(true)
              if (error instanceof ApiError && error.status === 401) expired.current()
            }
          })
          .finally(() => {
            if (!controller.signal.aborted) setBusy(false)
          })
      },
      q ? 200 : 0,
    )
    return () => {
      clearTimeout(timer)
      controller.abort()
      pending.current?.abort()
    }
  }, [api, q, source, reload, restoring])

  async function more() {
    if (busy || !data?.nextCursor) return
    const controller = new AbortController()
    pending.current = controller
    setBusy(true)
    setFailed(false)
    try {
      const next = await api.listPlaylists(
        { q: q.trim(), ...(source ? { source } : {}), limit: 30, cursor: data.nextCursor },
        controller.signal,
      )
      if (!controller.signal.aborted)
        setData({
          ...next,
          playlists: [...new Map([...data.playlists, ...next.playlists].map((p) => [p.id, p])).values()],
        })
    } catch (error) {
      if (!controller.signal.aborted) {
        setFailed(true)
        if (error instanceof ApiError && error.status === 401) expired.current()
      }
    } finally {
      if (!controller.signal.aborted) setBusy(false)
    }
  }

  if (selected)
    return (
      <PlaylistDetail
        onInspire={onInspire}
        key={selected.id}
        api={api}
        initial={selected}
        onBack={() => setSelected(null)}
        onSessionExpired={onSessionExpired}
      />
    )
  return (
    <>
      <div className="ym-toolbar">
        <input
          aria-label="Search playlists"
          placeholder="Search playlists"
          maxLength={200}
          value={q}
          onChange={(event) => setQ(event.target.value)}
        />
        <span className="ym-source-select">
          <select
            aria-label="Filter source"
            value={source}
            onChange={(event) => setSource(event.target.value as typeof source)}
          >
            <option value="">All sources</option>
            <option value="apple">Apple Music</option>
            <option value="spotify_export">Spotify</option>
          </select>
        </span>
        <span className="ym-collection-meta" aria-live="polite">
          {data ? `${data.playlists.length} of ${data.total} playlists` : failed ? '' : 'Loading playlists…'}
        </span>
      </div>
      {data && failed && <p role="status">Couldn’t refresh your playlists. Your last loaded collection is still here. <button className="minimal-retry" onClick={() => setReload(n => n + 1)}>Retry</button></p>}
      {!data && failed ? (
        <MusicEmpty
          title="Couldn’t load your playlists"
          action="Try again"
          onAction={() => setReload((n) => n + 1)}
        >
          Your saved music hasn’t changed. Try loading the collection again.
        </MusicEmpty>
      ) : !data ? (
        <div className="ym-playlist-grid" aria-busy="true" aria-label="Loading playlists">
          {Array.from({ length: 6 }, (_, i) => (
            <div className="ym-skeleton ym-cover" key={i} />
          ))}
        </div>
      ) : data.playlists.length === 0 ? (
        <MusicEmpty
          title={q || source ? 'No matching playlists' : 'No playlists yet'}
          action={q || source ? 'Clear filters' : 'Manage sources'}
          onAction={() => (q || source ? (setQ(''), setSource('')) : onSources())}
        >
          {q || source
            ? 'Try another name or clear your search. Your music is still here.'
            : 'Playlists will appear here after you add some to a source and sync again.'}
        </MusicEmpty>
      ) : (
        <>
          <div className="ym-playlist-grid">
            {data.playlists.map((playlist) => (
              <button
                className="ym-playlist"
                key={playlist.id}
                aria-label={`Open ${playlist.name}`}
                onClick={() => setSelected(playlist)}
              >
                <PlaylistCover playlist={playlist} />
                <span className="ym-playlist-name">{playlist.name}</span>
                <span className="ym-playlist-meta">
                  {sourceLabel(playlist.source)} · {playlistMeta(playlist)}
                </span>
              </button>
            ))}
          </div>
          {data.nextCursor ? (
            <div className="ym-end-note">
              <button className="btn" disabled={busy} onClick={() => void more()}>
                {busy ? 'Loading more…' : failed ? 'Retry loading more' : 'Load more'}
              </button>
            </div>
          ) : null}
        </>
      )}
    </>
  )
}

function PlaylistDetail({
  onInspire,
  api,
  initial,
  onBack,
  onSessionExpired,
}: {
  onInspire?: (playlist: ApiPlaylistSummary) => void
  api: MixtapeApi
  initial: ApiPlaylistSummary
  onBack: () => void
  onSessionExpired: () => void
}) {
  const headingRef = useRef<HTMLHeadingElement>(null)
  const restoring = useWorkspaceRestoring()
  const [data, setData] = useRestorableState<Awaited<ReturnType<MixtapeApi['getPlaylist']>> | null>(`library.playlist.${initial.id}.data`, null)
  const [busy, setBusy] = useState(false)
  const [failed, setFailed] = useState(false)
  const [reload, setReload] = useState(0)
  const pending = useRef<AbortController | null>(null)
  const expired = useRef(onSessionExpired)
  expired.current = onSessionExpired
  useEffect(() => {
    const view = headingRef.current?.closest('.ym-view')
    if (view) view.scrollTop = 0
    headingRef.current?.focus({ preventScroll: true })
  }, [])
  useEffect(() => {
    if (restoring) return
    const controller = new AbortController()
    pending.current = controller
    setBusy(true)
    setFailed(false)
    void api
      .getPlaylist(initial.id, { entryLimit: 100 }, controller.signal)
      .then((value) => {
        if (!controller.signal.aborted) setData(value)
      })
      .catch((error) => {
        if (!controller.signal.aborted) {
          setFailed(true)
          if (error instanceof ApiError && error.status === 401) expired.current()
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) setBusy(false)
      })
    return () => {
      controller.abort()
      pending.current?.abort()
    }
  }, [api, initial.id, reload, restoring])
  async function more() {
    if (busy || !data?.nextEntryCursor) return
    const controller = new AbortController()
    pending.current = controller
    setBusy(true)
    setFailed(false)
    try {
      const next = await api.getPlaylist(
        initial.id,
        { entryLimit: 100, entryCursor: data.nextEntryCursor },
        controller.signal,
      )
      if (!controller.signal.aborted)
        setData({
          ...next,
          entries: [...new Map([...data.entries, ...next.entries].map((e) => [e.id, e])).values()],
        })
    } catch (error) {
      if (!controller.signal.aborted) {
        setFailed(true)
        if (error instanceof ApiError && error.status === 401) expired.current()
      }
    } finally {
      if (!controller.signal.aborted) setBusy(false)
    }
  }
  const playlist = data?.playlist ?? initial
  return (
    <>
      <button className="ym-back" onClick={onBack}>
        ← All playlists
      </button>
      <div className="ym-detail-head">
        <PlaylistCover playlist={playlist} />
        <div>
          <p className="quiet-kicker">{sourceLabel(playlist.source)}</p>
          <h2 ref={headingRef} tabIndex={-1}>
            {playlist.name}
          </h2>
          <p>
            {playlistMeta(playlist)}
            {playlist.syncedAt ? ` · Synced ${musicDate(playlist.syncedAt)}` : ''}
          </p>
          {onInspire && (
            <button
              className="btn primary ym-detail-action"
              disabled={!data || !playlist.inLibrary}
              onClick={() => onInspire(playlist)}
            >
              Make a mix inspired by this
            </button>
          )}
        </div>
        {data ? (
          <PlaylistTasteControls playlist={playlist} api={api} onChanged={(next) => setData(current => current ? { ...current, playlist: next } : current)} onSessionExpired={onSessionExpired} />
        ) : !failed ? (
          <div className="wc-taste" aria-hidden="true">
            <span className="ym-bone" style={{ width: 'min(440px, 100%)' }} />
          </div>
        ) : null}
      </div>
      {!data && failed ? (
        <MusicEmpty
          title="Couldn’t load the tracks"
          action="Try again"
          onAction={() => setReload((n) => n + 1)}
        >
          The playlist is still saved. Try loading its tracks again.
        </MusicEmpty>
      ) : !data ? (
        <DetailSkeleton playlist={playlist} />
      ) : (
        <>
          <ol className="ym-tracklist">
            {data.entries.map((entry) => (
              <li key={entry.id} className="ym-track">
                <span className="ym-position">{entry.position + 1}</span>
                <div>
                  <div className="ym-track-name">{entry.title}</div>
                  <div className="ym-track-artist">
                    {entry.artist}
                    {entry.durationMs !== null ? ` · ${duration(entry.durationMs)}` : ''}
                  </div>
                </div>
                {playlist.source === 'spotify_export' &&
                entry.spotifyId &&
                /^[A-Za-z0-9]{22}$/.test(entry.spotifyId) ? (
                  <a
                    className="btn"
                    href={`https://open.spotify.com/track/${entry.spotifyId}`}
                    target="_blank"
                    rel="noopener noreferrer"
                  >
                    Open in Spotify
                  </a>
                ) : entry.appleCatalogId ? (
                  <span className="ym-duration">
                    {entry.durationMs !== null ? duration(entry.durationMs) : 'Duration unknown'}
                  </span>
                ) : (
                  <span className="ym-unavailable">Unavailable on the web</span>
                )}
              </li>
            ))}
          </ol>
          <p className="ym-provider-note">
            Showing {data.entries.length} of {playlist.entryCount} tracks. Original order and repeated songs
            are preserved. Local or unresolved entries stay visible.
          </p>
          {failed ? <p role="status">Couldn’t refresh the tracks. Your loaded tracks are still here. <button className="minimal-retry" onClick={() => setReload(n => n + 1)}>Retry</button></p> : null}
          {data.nextEntryCursor ? (
            <button className="btn" disabled={busy} onClick={() => void more()}>
              {busy ? 'Loading tracks…' : failed ? 'Retry loading more tracks' : 'Load more tracks'}
            </button>
          ) : null}
        </>
      )}
    </>
  )
}

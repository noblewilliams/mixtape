import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { createPortal } from 'react-dom'
import { ApiError, type ApiPlaylistSummary, type MixtapeApi } from '../api/client'

export type PlaylistAttachmentValue = {
  playlistId: string
  name: string
  source: 'apple' | 'spotify_export'
  excludeSourceTracks: boolean
  status?: 'ready' | 'unavailable' | 'insufficient_profile'
}
export function PlaylistAttachment({
  api,
  value,
  onSelect,
  onSessionExpired,
  disabled = false,
  onReload,
}: {
  api: MixtapeApi
  value: PlaylistAttachmentValue | null
  onSelect: (value: PlaylistAttachmentValue | null) => Promise<void>
  onSessionExpired: () => void
  disabled?: boolean
  onReload?: () => Promise<void>
}) {
  const [open, setOpen] = useState(false)
  const [query, setQuery] = useState('')
  const [data, setData] = useState<{ playlists: ApiPlaylistSummary[]; nextCursor: string | null } | null>(
    null,
  )
  const [loading, setLoading] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [retry, setRetry] = useState(0)
  const anchor = useRef<HTMLDivElement>(null)
  const picker = useRef<HTMLDivElement>(null)
  const [position, setPosition] = useState({ left: 16, top: 16, width: 300, maxHeight: 300 })
  useLayoutEffect(() => {
    if (!open) return
    const place = () => {
      const box = anchor.current!.getBoundingClientRect()
      const width = Math.min(330, window.innerWidth - 32)
      const height = Math.min(320, window.innerHeight - 32)
      const measured = Math.min(picker.current?.scrollHeight ?? height, height)
      setPosition({
        left: Math.max(16, Math.min(box.left, window.innerWidth - width - 16)),
        top: Math.max(16, box.top - measured - 10),
        width,
        maxHeight: height,
      })
    }
    place()
    window.addEventListener('resize', place)
    window.addEventListener('scroll', place, true)
    return () => {
      window.removeEventListener('resize', place)
      window.removeEventListener('scroll', place, true)
    }
  }, [open, data, error])
  const request = useRef<AbortController | null>(null)
  const alive = useRef(true)
  const writing = useRef(false)
  const expired = useRef(onSessionExpired)
  expired.current = onSessionExpired
  useEffect(() => {
    alive.current = true
    return () => {
      alive.current = false
      request.current?.abort()
    }
  }, [])
  useEffect(() => {
    if (!open) return
    picker.current?.querySelector<HTMLInputElement>('input')?.focus()
    const outside = (e: PointerEvent) => {
      if (!anchor.current?.contains(e.target as Node) && !picker.current?.contains(e.target as Node))
        setOpen(false)
    }
    const escape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setOpen(false)
        anchor.current?.querySelector<HTMLButtonElement>('button')?.focus()
      }
    }
    document.addEventListener('pointerdown', outside)
    document.addEventListener('keydown', escape)
    return () => {
      document.removeEventListener('pointerdown', outside)
      document.removeEventListener('keydown', escape)
    }
  }, [open])
  useEffect(() => {
    if (!open) return
    const controller = new AbortController()
    request.current = controller
    setLoading(true)
    setData(null)
    setError('')
    const timer = setTimeout(
      () => {
        void api
          .listPlaylists({ q: query, limit: 20 }, controller.signal)
          .then((result) => {
            if (!controller.signal.aborted) setData(result)
          })
          .catch((e) => {
            if (controller.signal.aborted) return
            setError('Couldn’t load playlists. Try again.')
            if (e instanceof ApiError && e.status === 401) expired.current()
          })
          .finally(() => {
            if (!controller.signal.aborted) setLoading(false)
          })
      },
      query ? 200 : 0,
    )
    return () => {
      clearTimeout(timer)
      controller.abort()
      request.current?.abort()
    }
  }, [open, api, query, retry])
  async function more() {
    if (!data?.nextCursor || loading) return
    const controller = new AbortController()
    request.current = controller
    setLoading(true)
    try {
      const next = await api.listPlaylists(
        { q: query, limit: 20, cursor: data.nextCursor },
        controller.signal,
      )
      if (!controller.signal.aborted)
        setData({
          ...next,
          playlists: [...new Map([...data.playlists, ...next.playlists].map((p) => [p.id, p])).values()],
        })
    } catch (e) {
      if (!controller.signal.aborted) {
        setError('Couldn’t load more playlists.')
        if (e instanceof ApiError && e.status === 401) expired.current()
      }
    } finally {
      if (!controller.signal.aborted) setLoading(false)
    }
  }
  async function choose(next: PlaylistAttachmentValue | null, close = true) {
    if (writing.current || disabled) return
    writing.current = true
    setBusy(true)
    setError('')
    try {
      await onSelect(next)
      if (alive.current && close) setOpen(false)
    } catch {
      if (alive.current)
        setError('Couldn’t attach that playlist. Review the current selection and try again.')
    } finally {
      writing.current = false
      if (alive.current) setBusy(false)
    }
  }
  return (
    <div className="wc-attachment" ref={anchor}>
      <div className="wc-attachment-line">
        {value ? (
          <>
            <button
              type="button"
              className="wc-text wc-attached-label"
              disabled={disabled || busy}
              onClick={() => setOpen(!open)}
              aria-expanded={open}
            >
              Inspired by {value.name}
            </button>
            <button
              type="button"
              className="wc-text"
              aria-label="Detach playlist inspiration"
              disabled={disabled || busy}
              onClick={() => void choose(null)}
            >
              ×
            </button>
          </>
        ) : (
          <button
            type="button"
            className="wc-text"
            aria-label="Attach playlist inspiration"
            disabled={disabled || busy}
            aria-expanded={open}
            onClick={() => setOpen(!open)}
          >
            ＋ Playlist
          </button>
        )}
      </div>
      {value?.status && value.status !== 'ready' && (
        <small role="status">
          {value.status === 'unavailable'
            ? 'Playlist unavailable. Replace or detach it.'
            : 'At least 3 matched recordings are needed. Replace or detach it.'}
        </small>
      )}
      {onReload && (
        <button
          type="button"
          className="wc-text"
          disabled={busy}
          onClick={async () => {
            setBusy(true)
            setError('')
            try {
              await onReload()
            } catch {
              if (alive.current) setError('Couldn’t refresh inspiration. Try again.')
            } finally {
              if (alive.current) setBusy(false)
            }
          }}
        >
          Reload inspiration
        </button>
      )}
      {busy && <small role="status">Saving inspiration…</small>}
      {error && <small role="alert">{error}</small>}
      {open &&
        createPortal(
          <div
            ref={picker}
            style={{ ...position, position: 'fixed', bottom: 'auto' }}
            className="wc-popover wc-playlist-picker"
            role="region"
            aria-label="Playlist inspiration"
          >
            <header>
              <strong>Playlist inspiration</strong>
              <button
                type="button"
                className="wc-text"
                onClick={() => setOpen(false)}
                aria-label="Close playlist picker"
              >
                ×
              </button>
            </header>
            <input
              type="search"
              aria-label="Find a playlist"
              placeholder="Find a playlist"
              value={query}
              maxLength={200}
              onChange={(e) => setQuery(e.target.value)}
            />
            {!data && loading ? (
              <p role="status">Loading playlists…</p>
            ) : !data ? (
              <button type="button" className="wc-text" onClick={() => setRetry((n) => n + 1)}>
                Retry
              </button>
            ) : (
              <>
                {data.playlists.length === 0 && <p>No matching playlists.</p>}
                {data.playlists.map((playlist) => (
                  <button
                    type="button"
                    key={playlist.id}
                    className="wc-pick-row"
                    disabled={busy || disabled}
                    onClick={() =>
                      void choose({
                        playlistId: playlist.id,
                        name: playlist.name,
                        source: playlist.source,
                        excludeSourceTracks: value?.excludeSourceTracks ?? false,
                      })
                    }
                  >
                    <strong>{playlist.name}</strong>
                    <small>
                      {playlist.source === 'apple' ? 'Apple Music' : 'Spotify'} · {playlist.entryCount} songs
                    </small>
                  </button>
                ))}
                {data.nextCursor && (
                  <button type="button" className="wc-text" disabled={loading} onClick={() => void more()}>
                    {loading ? 'Loading…' : 'Load more'}
                  </button>
                )}
              </>
            )}
            {value && (
              <label className="wc-check">
                <input
                  type="checkbox"
                  checked={value.excludeSourceTracks}
                  disabled={disabled || busy}
                  onChange={(e) => void choose({ ...value, excludeSourceTracks: e.target.checked }, false)}
                />
                Use different songs
              </label>
            )}
          </div>,
          document.body,
        )}
    </div>
  )
}

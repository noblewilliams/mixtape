import { EnergyAssessment } from './EnergyJourney'
import { useEffect, useRef, useState } from 'react'
import {
  ApiError,
  type MixtapeApi,
  type MixRestoreInput,
  type MixVersionDetail,
  type MixVersionList,
} from '../api/client'
import { ControlModal } from './ControlModal'
import './mix-history.css'

export function MixHistory({
  api,
  sessionId,
  onClose,
  onRestored,
  onSessionExpired,
  initialVersion,
}: {
  initialVersion?: number
  api: MixtapeApi
  sessionId: string
  onClose: () => void
  onRestored: () => Promise<void>
  onSessionExpired: () => void
}) {
  const [list, setList] = useState<MixVersionList | null>(null)
  const [detail, setDetail] = useState<MixVersionDetail | null>(null)
  const [busy, setBusy] = useState(false),
    [confirm, setConfirm] = useState(false),
    [error, setError] = useState('')
  const [retry, setRetry] = useState(false),
    [done, setDone] = useState<number | null>(null)
  const request = useRef<MixRestoreInput | null>(null),
    generation = useRef(0)
  const current = useRef(true)
  useEffect(() => {
    current.current = true
    void (initialVersion ? view(initialVersion) : load())
    return () => {
      current.current = false
      generation.current++
    }
  }, [api, sessionId, initialVersion])
  function fail(e: unknown) {
    if (e instanceof ApiError && e.status === 401) {
      onSessionExpired()
      return
    }
    setError(
      e instanceof ApiError && e.status === 404
        ? 'This version is unavailable. Older mixes may not have saved history.'
        : 'Couldn’t load versions. Try again.',
    )
  }
  async function load(before?: number) {
    const g = ++generation.current
    setBusy(true)
    setError('')
    try {
      const value = await api.listMixVersions(sessionId, before)
      if (!current.current || g !== generation.current) return
      setList((old) =>
        before && old
          ? { ...value, versions: [...old.versions, ...value.versions] }
          : value,
      )
      setDetail(null)
      setConfirm(false)
      setRetry(false)
      request.current = null
    } catch (e) {
      if (current.current && g === generation.current) fail(e)
    } finally {
      if (current.current && g === generation.current) setBusy(false)
    }
  }
  async function view(version: number) {
    const g = ++generation.current
    setBusy(true)
    setError('')
    try {
      const value = await api.readMixVersion(sessionId, version)
      if (current.current && g === generation.current) {
        setDetail(value)
        setConfirm(false)
      }
    } catch (e) {
      if (current.current && g === generation.current) fail(e)
    } finally {
      if (current.current && g === generation.current) setBusy(false)
    }
  }
  async function restore() {
    if (!detail || busy) return
    request.current ??= {
      version: detail.version,
      expectedVersion: detail.currentVersion,
      requestId: crypto.randomUUID(),
    }
    setBusy(true)
    setError('')
    try {
      const result = await api.restoreMixVersion(sessionId, request.current)
      if (!current.current) return
      setDone(result.version)
      setRetry(false)
      setConfirm(false)
      await onRestored().catch(() => {
        if (current.current)
          setError(
            'Restored, but the current mix could not refresh. Reopen the mix to reload it.',
          )
      })
    } catch (e) {
      if (!current.current) return
      if (e instanceof ApiError && e.status === 401) {
        onSessionExpired()
        return
      }
      if (e instanceof ApiError && e.status === 409) {
        setError(
          'Your mix changed, or a recording is unavailable. Review the latest version.',
        )
        setRetry(false)
        setConfirm(false)
        request.current = null
        setDetail(null)
      } else {
        setError(
          'We couldn’t confirm the restore. Retry safely to check the same request.',
        )
        setRetry(true)
      }
    } finally {
      if (current.current) setBusy(false)
    }
  }
  return (
    <main className="conversation-panel mix-history-page">
      <header className="mh-header"><h2>Mix version history</h2><button disabled={busy} onClick={onClose}>Close history</button></header>
      <div className="mix-history">
        {done !== null ? (
          <>
            {error && <p role="alert">{error}</p>}
            <p role="status">
              Version {done} is ready. Playback and saved playlists have not
              changed.
            </p>
            <button className="wc-primary" onClick={onClose}>
              Back to mix
            </button>
          </>
        ) : (
          <>
            {error && <p role="alert">{error}</p>}
            {busy && (
              <p role="status">
                {confirm ? 'Restoring…' : 'Loading versions…'}
              </p>
            )}
            {confirm && detail ? (
              <ControlModal title={`Use version ${detail.version}?`} onClose={() => {if (!busy) {setConfirm(false); if(retry) onClose()}}}>
                {error && <p role="alert">{error}</p>}
                {busy && <p role="status">Restoring…</p>}
                <p>
                  This creates a new version. Your other versions stay
                  available. Any playlist you saved stays as it is.
                </p>
                <div className="mh-actions">
                  <button disabled={busy} onClick={() => void restore()}>
                    {retry ? 'Retry restore' : `Use version ${detail.version}`}
                  </button>
                  <button
                    disabled={busy || retry}
                    onClick={() => setConfirm(false)}
                  >
                    Cancel
                  </button>
                </div>
              </ControlModal>
            ) : detail ? (
              <>
                <h3>Version {detail.version}</h3>
                <EnergyAssessment detail={detail} />
                <ol>
                  {detail.entries.map((e) => (
                    <li key={e.position}>
                      <strong>{e.title}</strong>
                      <span>{e.artist}</span>
                      {!e.available && <span>Unavailable recording</span>}
                    </li>
                  ))}
                </ol>
                {!detail.entries.length && <p>This version has no songs.</p>}
                <div className="mh-actions">
                  <button
                    disabled={busy || detail.entries.some((e) => !e.available)}
                    onClick={() => setConfirm(true)}
                  >
                    Use this version
                  </button>
                  <button
                    disabled={busy}
                    onClick={() => (list ? setDetail(null) : void load())}
                  >
                    Back to versions
                  </button>
                </div>
              </>
            ) : (
              <>
                {list?.versions.map((v) => (
                  <div className="mh-row" key={v.version}>
                    <div>
                      <strong>
                        Version {v.version}
                        {v.version === list.currentVersion ? ' · current' : ''}
                      </strong>
                      <span>
                        {v.trackCount} songs
                        {v.restoredFrom
                          ? ` · restored from version ${v.restoredFrom}`
                          : ''}
                      </span>
                    </div>
                    <button
                      disabled={busy}
                      onClick={() => void view(v.version)}
                    >
                      View
                    </button>
                  </div>
                ))}
                {list && !list.versions.length && (
                  <p>No versions yet. History starts with your first mix.</p>
                )}
                {list?.versions.length === 1 && (
                  <p>
                    Earlier versions may not have been saved. Future changes
                    will be kept.
                  </p>
                )}
                {list?.nextBefore && (
                  <button
                    disabled={busy}
                    onClick={() => void load(list.nextBefore!)}
                  >
                    Older versions
                  </button>
                )}
                {error && (
                  <button disabled={busy} onClick={() => void load()}>
                    Review latest
                  </button>
                )}
              </>
            )}
          </>
        )}
      </div>
    </main>
  )
}

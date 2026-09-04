import { useEffect, useState } from 'react'
import type { ApiSeedTrack, MixtapeApi } from '../api/client'
import { parseSpotifyTrackLines } from '../lib/onboarding'

type PasteResult = {
  added: { title: string; artist: string }[]
  unrecognised: number
  unresolved: number
}

type PasteSongsBoxProps = {
  api: MixtapeApi
}

function plural(count: number, noun: string) {
  return `${count} ${noun}${count === 1 ? '' : 's'}`
}

export function PasteSongsBox({ api }: PasteSongsBoxProps) {
  const [text, setText] = useState('')
  const [busy, setBusy] = useState(false)
  const [seeds, setSeeds] = useState<ApiSeedTrack[]>([])
  const [result, setResult] = useState<PasteResult | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    let cancelled = false
    api
      .getSeedTracks()
      .then((response) => {
        if (!cancelled) setSeeds(response.tracks)
      })
      .catch(() => undefined)
    return () => {
      cancelled = true
    }
  }, [api])

  const parsed = parseSpotifyTrackLines(text)

  async function add() {
    setError('')
    if (parsed.ids.length === 0) {
      setResult({ added: [], unrecognised: parsed.unrecognised, unresolved: 0 })
      return
    }
    setBusy(true)
    try {
      const response = await api.postSeedTracks(parsed.ids)
      setResult({
        added: response.resolved.map((track) => ({ title: track.title, artist: track.artist })),
        unrecognised: parsed.unrecognised,
        unresolved: response.unresolved.length,
      })
      setSeeds((current) => [
        ...current,
        ...response.resolved
          .filter((track) => !current.some((seed) => seed.trackId === track.trackId))
          .map((track) => ({ ...track, album: null })),
      ])
      setText('')
    } catch {
      setError('Those songs couldn’t be added. Try again.')
    } finally {
      setBusy(false)
    }
  }

  async function remove(trackId: string) {
    setError('')
    try {
      await api.deleteSeedTrack(trackId)
      setSeeds((current) => current.filter((seed) => seed.trackId !== trackId))
    } catch {
      setError('That song couldn’t be removed. Try again.')
    }
  }

  return (
    <section className="card paste-box" aria-labelledby="paste-title">
      <p className="quiet-kicker">Paste songs from Spotify</p>
      <h3 id="paste-title">Seed the DJ with songs you love</h3>
      <p>In Spotify on your computer, select tracks, copy, and paste the links here. One per line.</p>
      <div className="field">
        <label htmlFor="paste-links">Links</label>
        <textarea
          id="paste-links"
          value={text}
          disabled={busy}
          spellCheck={false}
          onChange={(event) => setText(event.target.value)}
        />
      </div>
      <div className="btn-row">
        <button className="btn primary" type="button" onClick={() => void add()} disabled={busy || parsed.lines === 0}>
          {parsed.lines === 0 ? 'Add songs' : busy ? 'Adding…' : `Add ${plural(parsed.lines, 'song')}`}
        </button>
      </div>
      {error ? <p className="dialog-error" role="alert">{error}</p> : null}
      {result ? (
        <div className="mini-grid mini-grid--stack" role="status">
          {result.added.length > 0 ? (
            <div className="mini done">
              <strong>{plural(result.added.length, 'song')} added</strong>
              <small>{result.added.map((track) => `${track.title} · ${track.artist}`).join(' · ')}</small>
            </div>
          ) : null}
          {result.unrecognised > 0 ? (
            <div className="mini err">
              <strong>{plural(result.unrecognised, 'link')} not recognised</strong>
              <small>
                {result.unrecognised === 1
                  ? 'One line isn’t a Spotify track link.'
                  : `${result.unrecognised} lines aren’t Spotify track links.`}{' '}
                Nothing else was affected.
              </small>
            </div>
          ) : null}
          {result.unresolved > 0 ? (
            <div className="mini err">
              <strong>{plural(result.unresolved, 'song')} not found</strong>
              <small>Spotify links Mixtape couldn’t match to a song yet. Nothing else was affected.</small>
            </div>
          ) : null}
        </div>
      ) : null}
      {seeds.length > 0 ? (
        <div className="chips paste-seeds" aria-label="Seed songs">
          {seeds.map((seed) => (
            <span className="chip" key={seed.trackId}>
              {seed.title}
              <button
                className="chip-remove"
                type="button"
                onClick={() => void remove(seed.trackId)}
                aria-label={`Remove ${seed.title}`}
              >
                ×
              </button>
            </span>
          ))}
        </div>
      ) : null}
    </section>
  )
}

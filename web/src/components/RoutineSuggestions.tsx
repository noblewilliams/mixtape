import { useEffect, useRef, useState } from 'react'
import type { MixtapeApi, SuggestionsResponse } from '../api/client'
import { ControlModal } from './ControlModal'
import './routine-suggestions.css'
const zone = () => Intl.DateTimeFormat().resolvedOptions().timeZone
export function RoutineSuggestions({
  api,
  onCreate,
  busy = false,
}: {
  api: MixtapeApi
  onCreate: (prompt: string) => Promise<void>
  busy?: boolean
}) {
  const [data, setData] = useState<SuggestionsResponse | null>(null)
  const [error, setError] = useState('')
  const [working, setWorking] = useState(false)
  const [settings, setSettings] = useState(false)
  const [enabled, setEnabled] = useState(true)
  const latest = useRef({ onCreate, busy })
  latest.current = { onCreate, busy }
  const life = useRef(0),
    locked = useRef(false),
    readId = useRef(0)
  async function refresh() {
    const generation = life.current,
      request = ++readId.current
    try {
      const result = await api.getSuggestions(zone())
      if (life.current === generation && request === readId.current) {
        setData(result)
        setError('')
      }
    } catch {
      if (life.current === generation && request === readId.current)
        setError('Could not load suggestions. Try again.')
    }
  }
  useEffect(() => {
    life.current++
    void refresh()
    const update = () => {
      if (!locked.current && document.visibilityState !== 'hidden')
        void refresh()
    }
    const timer = setInterval(update, 60000)
    window.addEventListener('focus', update)
    return () => {
      life.current++
      clearInterval(timer)
      window.removeEventListener('focus', update)
    }
  }, [api])
  async function act(action: () => Promise<void>) {
    if (locked.current || busy) return
    locked.current = true
    readId.current++
    setWorking(true)
    setError('')
    try {
      await action()
    } catch {
      setError(
        'Could not complete that action. Refresh suggestions and try again.',
      )
    } finally {
      locked.current = false
      setWorking(false)
    }
  }
  const suggestion = data?.suggestion
  return (
    <section
      className="routine-suggestions"
      aria-label="Routine suggestions"
      aria-busy={working}
    >
      {suggestion && (
        <div className="routine-card">
          <p className="quiet-kicker">A familiar moment</p>
          <h2>{suggestion.title}</h2>
          <p>{suggestion.reason}</p>
          <div className="routine-actions">
            <button
              className="routine-primary"
              disabled={working || busy}
              onClick={() =>
                void act(async () => {
                  const generation = life.current
                  const result = await api.selectSuggestion(
                    suggestion.id,
                    zone(),
                  )
                  if (generation === life.current && !latest.current.busy)
                    await latest.current.onCreate(result.prompt)
                })
              }
            >
              {busy ? 'Making your mix…' : 'Make this mix'}
            </button>
            <button
              className="wc-text"
              disabled={working || busy}
              onClick={() =>
                void act(async () => {
                  const generation = life.current
                  await api.dismissSuggestion(suggestion.id, zone())
                  if (generation === life.current)
                    setData({ ...data!, suggestion: null, dismissed: true })
                })
              }
            >
              Not today
            </button>
          </div>
        </div>
      )}
      {!suggestion && data?.enabled && (
        <p role="status">
          {data.dismissed
            ? 'That suggestion is hidden for today.'
            : 'Your usual moments will appear here as Mixtape gets to know your routines.'}
        </p>
      )}
      {!data && !error && <p role="status">Checking your usual moments…</p>}
      {error && (
        <p role="alert">
          {error}{' '}
          <button
            className="wc-text"
            disabled={working}
            onClick={() => void refresh()}
          >
            Refresh suggestions
          </button>
        </p>
      )}
      <button
        className="wc-text"
        disabled={!data || working || busy}
        onClick={() => {
          setEnabled(data!.enabled)
          setSettings(true)
        }}
      >
        Suggestion settings
      </button>
      {settings && (
        <ControlModal
          title="Suggestions, on your terms."
          onClose={() => {
            if (!working) setSettings(false)
          }}
        >
          <label className="routine-check">
            <input
              type="checkbox"
              checked={enabled}
              disabled={working}
              onChange={(e) => setEnabled(e.target.checked)}
            />
            Suggest mixes from my routines
          </label>
          <p>
            Suggestions appear in Mixtape. They never start playing by
            themselves.
          </p>
          {error && <p role="alert">{error}</p>}
          <div className="routine-actions">
            <button
              className="routine-primary"
              disabled={working}
              onClick={() =>
                void act(async () => {
                  const generation = life.current
                  await api.saveSuggestionPreference(enabled)
                  if (generation !== life.current) return
                  setData({ enabled, suggestion: null, dismissed: false })
                  setSettings(false)
                  await refresh()
                })
              }
            >
              Save
            </button>
            <button
              className="wc-text"
              disabled={working}
              onClick={() => setSettings(false)}
            >
              Cancel
            </button>
          </div>
        </ControlModal>
      )}
    </section>
  )
}

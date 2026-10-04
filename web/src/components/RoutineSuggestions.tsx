import { useEffect, useRef, useState } from 'react'
import type { MixtapeApi, SuggestionsResponse } from '../api/client'
import { useRestorableState, useWorkspaceRestoring } from '../lib/workspace-restore'
import { MixSkeletons } from './UiStates'
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
  const [data, setData] = useRestorableState<SuggestionsResponse | null>('home.suggestions', null)
  const restoring = useWorkspaceRestoring()
  const [error, setError] = useState('')
  const [working, setWorking] = useState(false)
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
    if (restoring) return
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
  }, [api, restoring])
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
  if (data && !suggestion && !error) return null
  return (
    <section
      className="routine-suggestions"
      aria-label="Routine suggestions"
      aria-busy={working}
    >
      {suggestion && (
        <><h2>For this moment</h2><div className="routine-card"><img className="routine-tape" src="/tape.svg" alt=""/><div className="routine-copy"><h3>{suggestion.title}</h3><p>{suggestion.reason}</p></div>
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
        </div></>
      )}
      {!data && !error && <div aria-busy="true" aria-label="Loading recommendations"><h2>For this moment</h2><MixSkeletons count={1} /></div>}
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
    </section>
  )
}

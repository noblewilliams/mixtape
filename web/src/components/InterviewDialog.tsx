import { useState, type KeyboardEvent } from 'react'
import type { InterviewResponse, MixtapeApi } from '../api/client'
import { CloseIcon } from './Icons'

export const INTERVIEW_MAX_ARTISTS = 20
export const INTERVIEW_MAX_ANSWER = 300

type TextKey = 'playsMost' | 'listensWhen' | 'neverWants' | 'era'
type TextStep = { key: TextKey; title: string; hint: string; label: string }

const ARTIST_STEP = {
  title: 'Artists you would never skip',
  hint: `Type a name and press Enter. Up to ${INTERVIEW_MAX_ARTISTS}.`,
}

const TEXT_STEPS: TextStep[] = [
  {
    key: 'playsMost',
    title: 'What do you play most these days?',
    hint: 'Albums, artists, a playlist on repeat. Whatever is actually on.',
    label: 'Plays most',
  },
  {
    key: 'listensWhen',
    title: 'When do you listen, and to what?',
    hint: 'Mornings, the commute, cooking, late nights. Pair a moment with what fits it.',
    label: 'Listens when',
  },
  {
    key: 'neverWants',
    title: 'Anything you never want to hear?',
    hint: 'Genres, moods, explicit lyrics, a specific artist. Say it plainly; the DJ treats it as a rule.',
    label: 'Never',
  },
  {
    key: 'era',
    title: 'An era you keep returning to?',
    hint: 'A decade, a scene, a few years that still sound like home.',
    label: 'Era',
  },
]

const STEP_COUNT = TEXT_STEPS.length + 1

type InterviewDialogProps = {
  api: MixtapeApi
  onClose: () => void
  onComplete: (response: InterviewResponse) => void
}

export function InterviewDialog({ api, onClose, onComplete }: InterviewDialogProps) {
  const [step, setStep] = useState(0)
  const [artists, setArtists] = useState<string[]>([])
  const [draft, setDraft] = useState('')
  const [answers, setAnswers] = useState<Record<TextKey, string>>({
    playsMost: '',
    listensWhen: '',
    neverWants: '',
    era: '',
  })
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const textStep = step === 0 ? null : TEXT_STEPS[step - 1]
  const last = step === STEP_COUNT - 1

  function addArtist(name: string): string[] {
    const value = name.trim()
    if (!value || artists.length >= INTERVIEW_MAX_ARTISTS) return artists
    if (artists.some((artist) => artist.toLowerCase() === value.toLowerCase())) return artists
    const next = [...artists, value]
    setArtists(next)
    return next
  }

  function onArtistKey(event: KeyboardEvent<HTMLInputElement>) {
    if (event.key !== 'Enter') return
    event.preventDefault()
    addArtist(draft)
    setDraft('')
  }

  function removeArtist(name: string) {
    setArtists((current) => current.filter((artist) => artist !== name))
  }

  function canAdvance(): boolean {
    if (busy) return false
    if (step === 0) return artists.length > 0 || draft.trim().length > 0
    return true
  }

  async function finish() {
    setBusy(true)
    setError('')
    try {
      const response = await api.postInterview({
        surface: 'web',
        neverSkip: artists,
        playsMost: answers.playsMost.trim(),
        listensWhen: answers.listensWhen.trim(),
        neverWants: answers.neverWants.trim(),
        era: answers.era.trim(),
      })
      onComplete(response)
    } catch {
      setError('The DJ couldn’t save your answers. Try again.')
    } finally {
      setBusy(false)
    }
  }

  function next() {
    if (step === 0) {
      const names = addArtist(draft)
      setDraft('')
      if (names.length === 0) return
    }
    if (last) {
      void finish()
      return
    }
    setStep((current) => current + 1)
  }

  const title = textStep ? textStep.title : ARTIST_STEP.title
  const hint = textStep ? textStep.hint : ARTIST_STEP.hint

  return (
    <div className="overlay" role="presentation">
      <section className="dialog interview-dialog" role="dialog" aria-modal="true" aria-labelledby="interview-title">
        <button className="dialog-close" type="button" onClick={onClose} aria-label="Close interview" disabled={busy}>
          <CloseIcon />
        </button>
        <p className="quiet-kicker">Tell the DJ about your taste · {step + 1} of {STEP_COUNT}</p>
        <h2 id="interview-title">{title}</h2>
        <p>{hint}</p>

        {textStep ? (
          <div className="field">
            <label htmlFor={`interview-${textStep.key}`}>{textStep.label}</label>
            <textarea
              id={`interview-${textStep.key}`}
              value={answers[textStep.key]}
              maxLength={INTERVIEW_MAX_ANSWER}
              disabled={busy}
              onChange={(event) => setAnswers((current) => ({ ...current, [textStep.key]: event.target.value }))}
            />
            <span className="note field-counter" aria-live="polite">
              {answers[textStep.key].length} / {INTERVIEW_MAX_ANSWER}
            </span>
          </div>
        ) : (
          <div className="field">
            <label htmlFor="interview-artist">Artist</label>
            <input
              id="interview-artist"
              autoFocus
              value={draft}
              placeholder="Ivory Kestrel"
              maxLength={80}
              disabled={busy || artists.length >= INTERVIEW_MAX_ARTISTS}
              onChange={(event) => setDraft(event.target.value)}
              onKeyDown={onArtistKey}
            />
            {artists.length > 0 ? (
              <div className="chips" aria-label="Artists you would never skip">
                {artists.map((artist) => (
                  <span className="chip" key={artist}>
                    {artist}
                    <button
                      className="chip-remove"
                      type="button"
                      onClick={() => removeArtist(artist)}
                      aria-label={`Remove ${artist}`}
                      disabled={busy}
                    >
                      ×
                    </button>
                  </span>
                ))}
              </div>
            ) : null}
          </div>
        )}

        <div className="stepper" aria-hidden="true">
          {Array.from({ length: STEP_COUNT }, (_, index) => (
            <span className={index <= step ? 'on' : ''} key={index} />
          ))}
        </div>

        {error ? <p className="dialog-error" role="alert">{error}</p> : null}

        <div className="dialog-actions">
          <button className="btn" type="button" onClick={() => setStep((current) => current - 1)} disabled={step === 0 || busy}>
            Back
          </button>
          <button className="btn primary" type="button" onClick={next} disabled={!canAdvance()}>
            {last ? (busy ? 'Saving…' : 'Finish') : 'Next'}
          </button>
        </div>
      </section>
    </div>
  )
}

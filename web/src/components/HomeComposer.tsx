import { useEffect, useRef, useState } from 'react'
import { useRestorableState } from '../lib/workspace-restore'
import type { SessionKind } from '../domain'
import { PromptComposer, type PromptComposerProps } from './PromptComposer'
import { EnergyControl, type EnergyArc } from './EnergyJourney'
import { ModeControl } from './ModeControl'

/** A prompt put back into the field from outside (the cap's kept prompt after a failed sign-in). */
export type DraftSeed = { text: string; id: number }
export type HomeSubmit = (prompt: string, options: { kind: SessionKind; shape?: EnergyArc }) => void | Promise<void>

type Props = Pick<PromptComposerProps, 'busy' | 'transcribe'> & {
  albumPicks: boolean
  anonymous: boolean
  onSubmit: HomeSubmit
  draftSeed?: DraftSeed | null
}

// Starters are prompts, not settings: they fill the field and never send.
const starters: Record<SessionKind, string[]> = {
  mix: ['Kitchen, early, coffee on', 'Running, long, no lyrics', 'Last bus home'],
  album: ['Rainy evening, start to finish', 'Something I have never heard', 'One I own and forgot'],
}
const asksForAlbum = /\balbums?\b/i

export function HomeComposer({ draftSeed, albumPicks, anonymous, onSubmit, busy = false, transcribe }: Props) {
  const [draft, setDraft] = useRestorableState('home.draft', '')
  // A mode, not a setting: Mix again on every mount, never stored.
  const [mode, setMode] = useState<SessionKind>('mix')
  const [shape, setShape] = useState<EnergyArc | null>(null)
  const [nudge, setNudge] = useState<'none' | 'shown' | 'kept'>('none')
  const matched = useRef(false)
  const root = useRef<HTMLDivElement>(null)
  const control = albumPicks && !anonymous
  const kind = control ? mode : 'mix'
  const nudged = control && nudge === 'shown' && mode === 'album'

  useEffect(() => {
    if (draftSeed) setDraft(draftSeed.text)
  }, [draftSeed?.id])

  useEffect(() => {
    const matches = asksForAlbum.test(draft)
    const arrived = matches && !matched.current
    // A restored draft that already matches on mount only records the match: no nudge (albumPicks is still false until getMe), by intent.
    matched.current = matches
    if (!draft.trim()) { setNudge('none'); return }
    if (arrived && control && mode === 'mix' && nudge === 'none') { setMode('album'); setNudge('shown') }
  }, [draft])

  function choose(next: SessionKind) {
    setMode(next)
    if (next === 'mix' && nudge === 'shown') setNudge('kept')
  }

  return <div className="home-compose-area" ref={root}>
    <PromptComposer draft={draft} setDraft={setDraft} busy={busy} transcribe={transcribe}
      sendLabel={kind === 'album' ? 'Find an album' : 'Make a mix'}
      submitError={kind === 'album' ? 'Couldn’t find an album. Your prompt is still here, try again.' : undefined}
      inputPlaceholder={kind === 'album' ? 'What kind of record are you in the mood for…' : undefined}
      onSubmit={async prompt => {
        await onSubmit(prompt, kind === 'mix' && shape ? { kind, shape } : { kind })
        setShape(null)
      }}
      tools={<>
        {control && <ModeControl value={mode} onChange={choose} disabled={busy} />}
        {kind === 'mix' && <EnergyControl compact value={shape} onSelect={setShape} disabled={busy} />}
      </>}
    />
    {/* The live region stays mounted so the nudge is announced as it arrives. */}
    {control && <div className="home-switched" role="status">{nudged && <>Switched to Album for this prompt. <button type="button" onClick={() => choose('mix')}>Keep it a mix</button></>}</div>}
    {!nudged && <div className="home-starters">{starters[kind].map(text => <button key={text} type="button" disabled={busy} onClick={() => {
      setDraft(text)
      root.current?.querySelector('textarea')?.focus()
    }}>{text}</button>)}</div>}
  </div>
}

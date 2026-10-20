import { useEffect } from 'react'
import { useRestorableState } from '../lib/workspace-restore'
import { PromptComposer, type PromptComposerProps } from './PromptComposer'

/** A prompt put back into the field from outside (the cap's kept prompt after a failed sign-in). */
export type DraftSeed = { text: string; id: number }

type Props = Pick<PromptComposerProps, 'onSubmit' | 'busy' | 'transcribe'> & { draftSeed?: DraftSeed | null }

export function HomeComposer({ draftSeed, ...props }: Props) {
  const [draft, setDraft] = useRestorableState('home.draft', '')
  useEffect(() => {
    if (draftSeed) setDraft(draftSeed.text)
  }, [draftSeed?.id])
  return <PromptComposer {...props} draft={draft} setDraft={setDraft} />
}

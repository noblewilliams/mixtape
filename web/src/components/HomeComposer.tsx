import { useRestorableState } from '../lib/workspace-restore'
import { PromptComposer, type PromptComposerProps } from './PromptComposer'

type Props = Pick<PromptComposerProps, 'onSubmit' | 'busy' | 'transcribe'>

export function HomeComposer(props: Props) {
  const [draft, setDraft] = useRestorableState('home.draft', '')
  return <PromptComposer {...props} draft={draft} setDraft={setDraft} />
}

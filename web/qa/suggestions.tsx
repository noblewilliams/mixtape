import { createRoot } from 'react-dom/client'
import { RoutineSuggestions } from '../src/components/RoutineSuggestions'
import { createFakeApi } from '../src/test/fake-api'
import '../src/styles.css'
import '../src/components/web-controls.css'
let enabled = true,
  dismissed = false
const suggestion = {
  id: '5-3-fall',
  title: 'Ease into a slower pace.',
  reason: 'You have made winding-down mixes on 3 Friday evenings.',
  prompt: 'Make a mix that gradually winds down.',
}
const api = createFakeApi({
  getSuggestions: async () => ({
    enabled,
    suggestion: enabled && !dismissed ? suggestion : null,
    dismissed,
  }),
  dismissSuggestion: async () => {
    dismissed = true
    return { ok: true }
  },
  saveSuggestionPreference: async (value) => {
    enabled = value
    return { enabled }
  },
  selectSuggestion: async () => ({ prompt: suggestion.prompt }),
})
createRoot(document.getElementById('root')!).render(
  <main
    style={{
      background: 'var(--surface)',
      color: 'var(--graphite)',
      minHeight: '100vh',
      padding: 16,
      maxWidth: 850,
      margin: 'auto',
    }}
  >
    <h1>Your tapes</h1>
    <RoutineSuggestions api={api} onCreate={async () => {}} />
  </main>,
)

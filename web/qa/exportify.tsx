// Local visual acceptance harness; never imported by the application entry point.
import { createRoot } from 'react-dom/client'
import { SpotifyMusicView } from '../src/components/SpotifyMusicView'
import { createFakeApi } from '../src/test/fake-api'
import { createDirectParser } from '../src/import/direct-parser'
import { createListeningImportService } from '../src/import/import-service'
import { createImportRun } from '../src/import/import-run'
import '../src/styles.css'
import '../src/components/your-music.css'
const api = createFakeApi()
const parser = createDirectParser()
const run = createImportRun({
  parser,
  importService: createListeningImportService({ api, parser }),
  onImported: () => {},
})
const state = new URLSearchParams(location.search).get('state')
if (state === 'review')
  run.take(
    new File(
      [
        'Track URI,Track Name,Artist Name(s),Album Name\nspotify:track:4uLU6hMCjMI75M1A2tKUQC,Quiet mornings,Orchard Choir,Moon\nspotify:track:7ouMYWpwJ422jRcDASZB7P,Soft light,Orchard Choir,Moon\n',
      ],
      'quiet_mornings.csv',
      { type: 'text/csv' },
    ),
  )
createRoot(document.getElementById('root')!).render(
  <div className="app-shell" style={{ display: 'block' }}>
    <div
      className="ym-view"
      style={{ padding: 24, maxWidth: 1100, margin: '0 auto', height: '100%' }}
    >
      <SpotifyMusicView
        embedded
        api={api}
        importRun={run}
        onboarding={{
          userId: 'preview',
          sources: [],
          hasLibrary: false,
          chosenService: 'spotify',
          markedRequestedAt: null,
          interviewCompletedAt: null,
          importCompletedAt: null,
          interview: null,
        }}
        interviewStatus=""
        onRefresh={async () => {}}
        onOpenInterview={() => {}}
        onNewTape={() => {}}
        onRemoveSource={() => {}}
      />
    </div>
  </div>,
)

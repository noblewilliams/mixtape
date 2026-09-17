// Synthetic state only. No provider playback or user data in this harness.
import { createRoot } from 'react-dom/client'
import { PlaybackController } from '../src/playback/controller'
import { PlaybackPanel } from '../src/components/PlaybackPanel'
import { createFakeApi } from '../src/test/fake-api'
import type { MusicKitClient } from '../src/musickit/client'
import '../src/styles.css'
import '../src/components/web-controls.css'
const controller = new PlaybackController(
  createFakeApi(),
  {
    play: async () => {},
    pause: async () => {},
    next: async () => {},
    previous: async () => {},
    resume: async () => {},
    seek: async () => {},
    stop: async () => {},
  } as unknown as MusicKitClient,
  'synthetic-preview',
)
await controller.initialize()
await controller.start('synthetic', 4, 'Sunday, unhurried', [
  {
    position: 0,
    trackId: 'synthetic',
    appleId: 'synthetic',
    spotifyId: null,
    title: 'Paper Lanterns',
    artist: 'The Harbour Room',
    durationMs: 200000,
  },
])
createRoot(document.getElementById('root')!).render(
  <main
    style={{
      background: 'var(--surface)',
      color: 'var(--plum)',
      height: '100vh',
      padding: 24,
    }}
  >
    <h1>Sunday, unhurried</h1>
    <PlaybackPanel controller={controller} />
  </main>,
)

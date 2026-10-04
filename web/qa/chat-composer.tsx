import { createRoot } from 'react-dom/client'
import { Conversation } from '../src/components/Conversation'
import { demoSessions } from '../src/data/demo'
import { initializeTheme } from '../src/theme'
import '../src/styles.css'
import '../src/ui-polish.css'
import '../src/components/navigation-layout.css'
import '../src/components/web-controls.css'
initializeTheme()
createRoot(document.getElementById('root')!).render(<div style={{ background: 'var(--surface)', color: 'var(--graphite)', maxWidth: 900, width: '100%', height: '100dvh', margin: 'auto', display: 'flex', flexDirection: 'column' }}><p style={{ padding: '0 20px', fontSize: 12 }}>Local preview · synthetic mix · voice service unavailable</p><Conversation session={demoSessions[0]} messages={[]} thinking={false} currentShape="arc" attachment={<div className="wc-attachment"><button className="wc-text" type="button">＋ Playlist</button></div>} onSend={() => {}} onOpenQueue={() => {}} /></div>)

import { useState } from 'react'
import { createRoot } from 'react-dom/client'
import {
  EnergyControl,
  EnergyAssessment,
} from '../src/components/EnergyJourney'
import '../src/styles.css'
import '../src/components/web-controls.css'
function Preview() {
  const [text, setText] = useState('Sunday, unhurried')
  return (
    <main
      style={{
        background: 'var(--surface)',
        color: 'var(--plum)',
        minHeight: '100vh',
        padding: 24,
      }}
    >
      <h1>Sunday, unhurried</h1>
      <EnergyControl text={text} onChange={setText} />
      <textarea
        aria-label="Mix brief"
        style={{ width: '100%', minHeight: 100 }}
        value={text}
        onChange={(e) => setText(e.target.value)}
      />
      <EnergyAssessment
        detail={{
          energyArc: 'arc',
          energyJourney: {
            status: 'limited',
            known: 2,
            total: 10,
            bands: null,
          },
        }}
      />
    </main>
  )
}
createRoot(document.getElementById('root')!).render(<Preview />)

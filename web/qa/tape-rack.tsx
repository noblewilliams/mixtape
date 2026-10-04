// Synthetic local preview of the production rack component.
import { createRoot } from 'react-dom/client'
import { TapeRack } from '../src/components/TapeRack'
import { demoSessions } from '../src/data/demo'
import '../src/styles.css'
const names = ['Blue hour, windows down', 'Sunday kitchen radio', 'After midnight', 'Old friends', 'No rush home', 'Abuja after rain', 'Golden morning', 'Small victories', 'Soft landing', 'The long way home']
const colors = ['#c0c2b7', '#78555b', '#c78c6b', '#50654e', '#d6ccb8', '#697787', '#994a4d', '#454052', '#b9a3ab', '#8d9b9f']
const count = Number(new URLSearchParams(location.search).get('count') || 10)
createRoot(document.getElementById('root')!).render(<main style={{ padding: 24, maxWidth: 1000, margin: 'auto' }}><p>Local preview · synthetic mixes</p><TapeRack sessions={Array.from({ length: count }, (_, i) => ({ ...demoSessions[0], id: `mix-${i}`, title: names[i % 10], caseColor: colors[i % 10] }))} onOpenSession={() => {}} /></main>)

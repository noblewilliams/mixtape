import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { RootApp } from './RootApp'
import { installFocusModality } from './lib/focus-modality'
import { initializeTheme } from './theme'
import './styles.css'
import './ui-polish.css'
import './components/navigation-layout.css'

initializeTheme()
installFocusModality()

const root = createRoot(document.getElementById('root')!)
if (import.meta.env.DEV && new URLSearchParams(window.location.search).has('ui-preview')) {
  void import('./UiPolishPreview').then(({ default: Preview }) => root.render(<StrictMode><Preview /></StrictMode>))
} else {
  root.render(<StrictMode><RootApp /></StrictMode>)
}

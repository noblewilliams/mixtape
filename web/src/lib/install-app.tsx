import { useState, useSyncExternalStore } from 'react'

// Chromium fires beforeinstallprompt once, often before React mounts, so the
// event is held here from startup until Settings asks for it.
type InstallPromptEvent = Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> }

let deferred: InstallPromptEvent | null = null
const listeners = new Set<() => void>()
const notify = () => listeners.forEach((listener) => listener())

function capture(event: Event) {
  event.preventDefault()
  deferred = event as InstallPromptEvent
  notify()
}
function installed() {
  deferred = null
  notify()
}

let listening = false
function listen() {
  if (listening || typeof window === 'undefined') return
  listening = true
  window.addEventListener('beforeinstallprompt', capture)
  window.addEventListener('appinstalled', installed)
}

/** Called once at startup: holds the install prompt and registers the service worker in production. */
export function setUpInstallableApp(base: string = import.meta.env.BASE_URL) {
  listen()
  if (!import.meta.env.PROD || !('serviceWorker' in navigator)) return
  window.addEventListener('load', () => {
    void navigator.serviceWorker.register(`${base}sw.js`, { scope: base }).catch(() => undefined)
  })
}

export function resetInstallPromptForTest() {
  deferred = null
}

function subscribe(listener: () => void) {
  listen()
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}

export function isStandalone(): boolean {
  if (typeof window === 'undefined') return false
  return Boolean((navigator as Navigator & { standalone?: boolean }).standalone)
    || Boolean(window.matchMedia?.('(display-mode: standalone)')?.matches)
}

/** iOS has no install prompt; the only path is Safari's share sheet. */
export function installHint(userAgent: string): string | null {
  return /iPhone|iPad|iPod/.test(userAgent) ? 'In Safari, tap Share, then Add to Home Screen.' : null
}

type RowProps = { userAgent?: string; standalone?: boolean }

export function InstallAppRow({ userAgent = navigator.userAgent, standalone = isStandalone() }: RowProps) {
  const prompt = useSyncExternalStore(subscribe, () => deferred, () => null)
  const [busy, setBusy] = useState(false)
  const hint = installHint(userAgent)
  if (standalone || (!prompt && !hint)) return null

  async function install() {
    if (!prompt) return
    setBusy(true)
    try {
      await prompt.prompt()
      await prompt.userChoice
    } finally {
      // A prompt can be shown only once; Chromium fires a fresh event if it may ask again.
      installed()
      setBusy(false)
    }
  }

  return (
    <div className="setting-row">
      <span>
        <strong>Install Mixtape</strong>
        <small>{prompt ? 'Open Mixtape from your home screen, full screen, like an app.' : hint}</small>
      </span>
      {prompt && <button className="wc-text" disabled={busy} onClick={() => void install()}>Install</button>}
    </div>
  )
}

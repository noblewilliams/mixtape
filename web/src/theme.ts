import { useEffect, useSyncExternalStore } from 'react'

export type Theme = 'light' | 'dark'
const storageKey = 'mixtape.theme'
const changeEvent = 'mixtape-theme-change'
let unavailableStoragePreference: Theme | undefined

function storedTheme(): Theme | undefined {
  try {
    const value = window.localStorage.getItem(storageKey)
    return value === 'light' || value === 'dark' ? value : undefined
  } catch {
    return unavailableStoragePreference
  }
}

function currentTheme(): Theme {
  return storedTheme() ?? (window.matchMedia?.('(prefers-color-scheme: dark)').matches ? 'dark' : 'light')
}

/** Apply before React renders so a saved theme does not flash the system theme. */
export function initializeTheme(): void {
  document.documentElement.dataset.theme = currentTheme()
}

export function setTheme(theme: Theme): void {
  unavailableStoragePreference = theme
  try {
    window.localStorage.setItem(storageKey, theme)
  } catch {
    // The choice still applies for this page when browser storage is unavailable.
  }
  document.documentElement.dataset.theme = theme
  window.dispatchEvent(new Event(changeEvent))
}

function subscribe(onChange: () => void): () => void {
  const media = window.matchMedia?.('(prefers-color-scheme: dark)')
  const update = () => { initializeTheme(); onChange() }
  const storage = (event: StorageEvent) => {
    if (event.key === storageKey || event.key === null) update()
  }
  window.addEventListener(changeEvent, update)
  window.addEventListener('storage', storage)
  media?.addEventListener('change', update)
  return () => {
    window.removeEventListener(changeEvent, update)
    window.removeEventListener('storage', storage)
    media?.removeEventListener('change', update)
  }
}

export function useTheme(): [Theme, (theme: Theme) => void] {
  const theme = useSyncExternalStore(subscribe, currentTheme, () => 'light' as const)
  useEffect(initializeTheme, [theme])
  return [theme, setTheme]
}

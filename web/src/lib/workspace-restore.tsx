import { createContext, useCallback, useContext, useEffect, useState, useSyncExternalStore, type Dispatch, type ReactNode, type SetStateAction } from 'react'
import type { AuthUser } from '../components/AuthGate'

const prefix = 'mixtape.workspace.v1:'
const identityKey = `${prefix}identity`
type Identity = { user: AuthUser }
type Scope = { userId: string; restoring: boolean }
const RestoreContext = createContext<Scope | null>(null)
type SharedEntry = { value: unknown; listeners: Set<() => void> }
/** useSharedRestorableState's values, one per key. */
const shared = new Map<string, SharedEntry>()

function read<T>(key: string): T | undefined {
  try {
    const value = sessionStorage.getItem(key)
    return value ? JSON.parse(value) as T : undefined
  } catch { return undefined }
}
function write(key: string, value: unknown) {
  try {
    const encoded = JSON.stringify(value)
    if (encoded.length <= 1_000_000) sessionStorage.setItem(key, encoded)
  } catch { /* Storage is optional; the current page still works. */ }
}

export function restoredIdentity(): AuthUser | null {
  const saved = read<Identity>(identityKey)?.user
  return saved && typeof saved.id === 'string' && typeof saved.name === 'string' && typeof saved.email === 'string' ? saved : null
}
export function rememberIdentity(user: AuthUser) { write(identityKey, { user }) }
export function clearWorkspaceRestore(userId?: string) {
  for (const key of [...shared.keys()]) {
    if (userId ? key.startsWith(`${prefix}${encodeURIComponent(userId)}:`) : true) shared.delete(key)
  }
  try {
    for (let i = sessionStorage.length - 1; i >= 0; i--) {
      const key = sessionStorage.key(i)
      if (key?.startsWith(userId ? `${prefix}${encodeURIComponent(userId)}:` : prefix)) sessionStorage.removeItem(key)
    }
    if (!userId || restoredIdentity()?.id === userId) sessionStorage.removeItem(identityKey)
  } catch { /* Storage can be unavailable. */ }
}

/**
 * Open this mix when the app next loads in this tab, through the same keys the
 * shell restores from. Used when an owner opens their own shared link.
 */
export function openMixOnNextLoad(userId: string, sessionId: string) {
  const scope = `${prefix}${encodeURIComponent(userId)}:`
  write(`${scope}activeSessionId`, sessionId)
  write(`${scope}activeView`, 'session')
}

export function WorkspaceRestoreProvider({ userId, restoring, children }: Scope & { children: ReactNode }) {
  return <RestoreContext.Provider value={{ userId, restoring }}>{children}</RestoreContext.Provider>
}
export function useWorkspaceRestoring() { return useContext(RestoreContext)?.restoring ?? false }

/** Cache presentation data in this tab only. It never authorizes API requests. */
export function useRestorableState<T>(key: string, initial: T | (() => T)): [T, Dispatch<SetStateAction<T>>] {
  const scope = useContext(RestoreContext)
  const storageKey = scope ? `${prefix}${encodeURIComponent(scope.userId)}:${key}` : null
  const [state, setState] = useState<T>(() => {
    const fallback = typeof initial === 'function' ? (initial as () => T)() : initial
    const saved = storageKey ? read<T>(storageKey) : undefined
    return saved === undefined ? fallback : saved
  })
  useEffect(() => {
    if (storageKey && !scope?.restoring) write(storageKey, state)
  }, [storageKey, state, scope?.restoring])
  return [state, setState]
}


/**
 * useRestorableState, but one value per key however many components hold it:
 * a mix's two composers (the conversation's and the tape's) edit one draft.
 * The value lives while any holder is mounted and is cached like any other.
 */
export function useSharedRestorableState<T>(key: string, initial: T | (() => T)): [T, Dispatch<SetStateAction<T>>] {
  const scope = useContext(RestoreContext)
  const storageKey = scope ? `${prefix}${encodeURIComponent(scope.userId)}:${key}` : null
  const id = storageKey ?? `memory:${key}`
  const restoring = scope?.restoring ?? false
  // One entry per key for the page's life (cleared with the cache), so a holder that
  // remounts finds the same value its peers are editing.
  let entry = shared.get(id)
  if (!entry) {
    const saved = storageKey ? read<T>(storageKey) : undefined
    entry = { value: saved === undefined ? (typeof initial === 'function' ? (initial as () => T)() : initial) : saved, listeners: new Set() }
    shared.set(id, entry)
  }
  const held = entry
  const subscribe = useCallback((listener: () => void) => {
    held.listeners.add(listener)
    return () => { held.listeners.delete(listener) }
  }, [held])
  const value = useSyncExternalStore(subscribe, () => held.value as T)
  const setValue = useCallback<Dispatch<SetStateAction<T>>>((next) => {
    const resolved = typeof next === 'function' ? (next as (current: T) => T)(held.value as T) : next
    if (Object.is(resolved, held.value)) return
    held.value = resolved
    if (storageKey && !restoring) write(storageKey, resolved)
    for (const listener of [...held.listeners]) listener()
  }, [held, storageKey, restoring])
  return [value, setValue]
}

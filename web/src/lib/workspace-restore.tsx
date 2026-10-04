import { createContext, useContext, useEffect, useState, type Dispatch, type ReactNode, type SetStateAction } from 'react'
import type { AuthUser } from '../components/AuthGate'

const prefix = 'mixtape.workspace.v1:'
const identityKey = `${prefix}identity`
type Identity = { user: AuthUser }
type Scope = { userId: string; restoring: boolean }
const RestoreContext = createContext<Scope | null>(null)

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
  try {
    for (let i = sessionStorage.length - 1; i >= 0; i--) {
      const key = sessionStorage.key(i)
      if (key?.startsWith(userId ? `${prefix}${encodeURIComponent(userId)}:` : prefix)) sessionStorage.removeItem(key)
    }
    if (!userId || restoredIdentity()?.id === userId) sessionStorage.removeItem(identityKey)
  } catch { /* Storage can be unavailable. */ }
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

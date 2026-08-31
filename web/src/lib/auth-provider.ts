export type AuthProvider = 'apple' | 'google'

const LAST_USED_KEY = 'mixtape.last-sign-in-provider'
const PENDING_KEY = 'mixtape.pending-sign-in-provider'

function provider(value: string | null): AuthProvider | null {
  return value === 'apple' || value === 'google' ? value : null
}

export type AuthPreferenceStore = {
  lastUsed: () => AuthProvider | null
  begin: (next: AuthProvider) => void
  promotePending: () => AuthProvider | null
  clearPending: () => void
}

export function createAuthPreferenceStore(local: Storage, session: Storage): AuthPreferenceStore {
  return {
    lastUsed: () => provider(local.getItem(LAST_USED_KEY)),
    begin: (next) => session.setItem(PENDING_KEY, next),
    promotePending: () => {
      const pending = provider(session.getItem(PENDING_KEY))
      session.removeItem(PENDING_KEY)
      if (!pending) return null
      local.setItem(LAST_USED_KEY, pending)
      return pending
    },
    clearPending: () => session.removeItem(PENDING_KEY),
  }
}

function memoryStorage(): Storage {
  const values = new Map<string, string>()
  return {
    get length() { return values.size },
    clear: () => values.clear(),
    getItem: (key) => values.get(key) ?? null,
    key: (index) => [...values.keys()][index] ?? null,
    removeItem: (key) => { values.delete(key) },
    setItem: (key, value) => { values.set(key, value) },
  }
}

function browserStorage(name: 'localStorage' | 'sessionStorage'): Storage {
  try {
    const storage = window[name]
    const probe = 'mixtape.storage-probe'
    storage.setItem(probe, '1')
    storage.removeItem(probe)
    return storage
  } catch {
    return memoryStorage()
  }
}

export const browserAuthPreferences = createAuthPreferenceStore(
  browserStorage('localStorage'),
  browserStorage('sessionStorage'),
)

export function authErrorFromSearch(search: string): string {
  const params = new URLSearchParams(search)
  const providerName = provider(params.get('auth_error'))
  if (!providerName) return ''

  if (providerName === 'google' && params.get('error') === 'account_not_linked') {
    return 'That Google account is not linked yet. Sign in with your usual method, then link Google from Account.'
  }

  const label = providerName === 'apple' ? 'Apple' : 'Google'
  return `${label} sign-in did not finish.`
}

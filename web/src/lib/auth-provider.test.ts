import { describe, expect, it } from 'vitest'
import { createAuthPreferenceStore } from './auth-provider'

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

describe('auth provider preference', () => {
  it('promotes a pending provider only after authentication succeeds', () => {
    const local = memoryStorage()
    const session = memoryStorage()
    const store = createAuthPreferenceStore(local, session)

    store.begin('google')

    expect(store.lastUsed()).toBeNull()
    expect(store.promotePending()).toBe('google')
    expect(store.lastUsed()).toBe('google')
    expect(store.promotePending()).toBeNull()
  })

  it('ignores invalid or missing stored values', () => {
    const local = memoryStorage()
    const session = memoryStorage()
    local.setItem('mixtape.last-sign-in-provider', 'email')
    session.setItem('mixtape.pending-sign-in-provider', 'unknown')

    const store = createAuthPreferenceStore(local, session)

    expect(store.lastUsed()).toBeNull()
    expect(store.promotePending()).toBeNull()
  })
})

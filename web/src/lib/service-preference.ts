// The per-user, per-device "service chosen" flag behind the sign-in gate.
// Choosing Apple records nothing on the server (it infers Apple only once a
// library syncs), so without this the gate would come back on every load.
// Storage may be blocked (private mode, disabled site data): every call
// swallows that and behaves as if nothing were stored.

export type ServiceChoice = 'apple' | 'spotify'

function storageKey(userId: string) {
  return `mixtape:service-choice:${userId}`
}

export function readServiceChoice(userId: string): ServiceChoice | null {
  try {
    const value = window.localStorage.getItem(storageKey(userId))
    return value === 'apple' || value === 'spotify' ? value : null
  } catch {
    return null
  }
}

export function writeServiceChoice(userId: string, choice: ServiceChoice) {
  try {
    window.localStorage.setItem(storageKey(userId), choice)
  } catch {
    // Storage blocked: the in-memory choice still carries this session.
  }
}

export function clearServiceChoice(userId: string) {
  try {
    window.localStorage.removeItem(storageKey(userId))
  } catch {
    // Nothing to clear if nothing could be written.
  }
}

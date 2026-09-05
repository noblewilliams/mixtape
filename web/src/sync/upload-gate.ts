export type UploadOwner = 'apple' | 'spotify'
export type UploadGate = {
  acquire(owner: UploadOwner): (() => void) | null
  getOwner(): UploadOwner | null
  subscribe(listener: () => void): () => void
}

export function createUploadGate(): UploadGate {
  let held: { owner: UploadOwner; token: symbol } | null = null
  const listeners = new Set<() => void>()
  const notify = () => {
    for (const listener of [...listeners]) listener()
  }
  return {
    acquire(owner) {
      if (held) return null
      const token = Symbol(owner)
      held = { owner, token }
      notify()
      return () => {
        if (held?.token !== token) return
        held = null
        notify()
      }
    },
    getOwner: () => held?.owner ?? null,
    subscribe(listener) {
      listeners.add(listener)
      return () => {
        listeners.delete(listener)
      }
    },
  }
}

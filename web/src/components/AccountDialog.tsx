import { useEffect, useState } from 'react'
import type { AuthProvider } from '../lib/auth-provider'
import { AppleMark, GoogleMark } from './ProviderMarks'

export type LinkedAccount = {
  id: string
  providerId: string
}

export type AccountBridge = {
  listAccounts: () => Promise<LinkedAccount[]>
  linkProvider: (provider: AuthProvider) => Promise<{ error?: string }>
  unlinkAccount: (accountId: string) => Promise<{ error?: string }>
}

type AccountDialogProps = {
  auth: AccountBridge
  lastUsed: AuthProvider | null
  notice?: string
  noticeTone?: 'success' | 'error'
  onClose: () => void
}

const PROVIDERS: AuthProvider[] = ['apple', 'google']

function providerLabel(provider: AuthProvider): string {
  return provider === 'apple' ? 'Apple' : 'Google'
}

export function AccountDialog({ auth, lastUsed, notice = '', noticeTone = 'success', onClose }: AccountDialogProps) {
  const [accounts, setAccounts] = useState<LinkedAccount[]>([])
  const [loading, setLoading] = useState(true)
  const [busyProvider, setBusyProvider] = useState<AuthProvider | null>(null)
  const [error, setError] = useState('')

  useEffect(() => {
    let cancelled = false
    auth.listAccounts()
      .then((next) => {
        if (!cancelled) setAccounts(next)
      })
      .catch(() => {
        if (!cancelled) setError('We couldn’t load your sign-in methods. Try again.')
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => { cancelled = true }
  }, [auth])

  useEffect(() => {
    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === 'Escape' && !busyProvider) onClose()
    }
    window.addEventListener('keydown', closeOnEscape)
    return () => window.removeEventListener('keydown', closeOnEscape)
  }, [busyProvider, onClose])

  async function link(provider: AuthProvider) {
    setError('')
    setBusyProvider(provider)
    try {
      const result = await auth.linkProvider(provider)
      if (result.error) {
        setError(result.error)
        setBusyProvider(null)
      }
    } catch {
      setError(`Could not link ${providerLabel(provider)}.`)
      setBusyProvider(null)
    }
  }

  async function unlink(account: LinkedAccount, provider: AuthProvider) {
    setError('')
    setBusyProvider(provider)
    try {
      const result = await auth.unlinkAccount(account.id)
      if (result.error) setError(result.error)
      else setAccounts((current) => current.filter(({ id }) => id !== account.id))
    } catch {
      setError(`Could not remove ${providerLabel(provider)}.`)
    } finally {
      setBusyProvider(null)
    }
  }

  return (
    <div className="overlay account-overlay" role="presentation" onMouseDown={(event) => {
      if (event.target === event.currentTarget && !busyProvider) onClose()
    }}>
      <section className="account-dialog" role="dialog" aria-modal="true" aria-labelledby="account-dialog-title">
        <header className="account-dialog-header">
          <div>
            <p className="account-kicker">Account</p>
            <h2 id="account-dialog-title">Ways to sign in</h2>
          </div>
          <button
            className="account-dialog-close"
            type="button"
            aria-label="Close account settings"
            onClick={onClose}
            disabled={busyProvider !== null}
            autoFocus
          >
            ×
          </button>
        </header>
        <p className="account-intro">Link another sign-in method without changing your mixes or your Apple Music connection.</p>

        <div className="account-provider-list" aria-busy={loading}>
          {PROVIDERS.map((provider) => {
            const account = accounts.find(({ providerId }) => providerId === provider)
            const linked = Boolean(account)
            const canRemove = linked && accounts.length > 1
            const label = providerLabel(provider)
            return (
              <div className="account-provider-row" key={provider}>
                <span className={`account-provider-icon account-provider-icon--${provider}`} aria-hidden="true">
                  {provider === 'apple' ? <AppleMark /> : <GoogleMark />}
                </span>
                <span className="account-provider-copy">
                  <strong>{label}{lastUsed === provider ? <em>last used</em> : null}</strong>
                  <small>{loading ? 'Checking…' : linked ? 'Connected to this account' : 'Not connected'}</small>
                </span>
                {loading ? (
                  <span className="account-provider-status">Checking</span>
                ) : !linked ? (
                  <button
                    className="account-provider-action"
                    type="button"
                    disabled={busyProvider !== null}
                    onClick={() => void link(provider)}
                  >
                    {busyProvider === provider ? `Opening ${label}…` : `Link ${label}`}
                  </button>
                ) : canRemove && account ? (
                  <button
                    className="account-provider-action account-provider-action--quiet"
                    type="button"
                    disabled={busyProvider !== null}
                    onClick={() => void unlink(account, provider)}
                  >
                    {busyProvider === provider ? `Removing ${label}…` : `Remove ${label}`}
                  </button>
                ) : (
                  <span className="account-provider-status">Connected</span>
                )}
              </div>
            )
          })}
        </div>

        <p className="account-note">Each provider confirms the account before anything is linked. Mixtape never merges accounts silently.</p>
        {notice ? (
          <p className={`account-notice account-notice--${noticeTone}`} role={noticeTone === 'error' ? 'alert' : 'status'}>
            {notice}
          </p>
        ) : null}
        {error ? <p className="account-error" role="alert">{error}</p> : null}
      </section>
    </div>
  )
}

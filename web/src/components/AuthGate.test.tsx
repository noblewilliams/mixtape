import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AuthGate, type AuthBridge } from './AuthGate'

function bridge(overrides: Partial<AuthBridge> = {}): AuthBridge {
  return {
    useSession: () => ({ data: null, isPending: false, error: null, refetch: vi.fn() }),
    signInWithApple: vi.fn(async () => ({})),
    signOut: vi.fn(async () => ({})),
    ...overrides,
  }
}

describe('Apple authentication gate', () => {
  afterEach(cleanup)

  it('shows the approved compact signed-out state', () => {
    render(<AuthGate auth={bridge()}>{() => <p>Signed in</p>}</AuthGate>)

    expect(screen.getByRole('heading', { name: 'A tape for right now.' })).toBeInTheDocument()
    expect(screen.queryByText('Your personal DJ')).not.toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Continue with Apple' })).toBeInTheDocument()
    expect(screen.queryByText('Signed in')).not.toBeInTheDocument()
  })

  it('keeps an accessible redirecting state while Apple opens', async () => {
    const signInWithApple = vi.fn(() => new Promise<{ error?: string }>(() => undefined))
    render(<AuthGate auth={bridge({ signInWithApple })}>{() => <p>Signed in</p>}</AuthGate>)

    fireEvent.click(screen.getByRole('button', { name: 'Continue with Apple' }))

    expect(await screen.findByRole('status')).toHaveTextContent('Opening Apple sign-in')
    expect(screen.getByRole('button', { name: 'Opening Apple…' })).toBeDisabled()
  })

  it('keeps the control in place and explains a sign-in failure', async () => {
    const signInWithApple = vi.fn(async () => ({ error: 'Apple sign-in did not finish.' }))
    render(<AuthGate auth={bridge({ signInWithApple })}>{() => <p>Signed in</p>}</AuthGate>)

    fireEvent.click(screen.getByRole('button', { name: 'Continue with Apple' }))

    await waitFor(() => expect(screen.getByRole('alert')).toHaveTextContent('Apple sign-in did not finish.'))
    expect(screen.getByRole('button', { name: 'Continue with Apple' })).toBeInTheDocument()
  })

  it('renders the application when a session is present', () => {
    const auth = bridge({
      useSession: () => ({
        data: { user: { id: 'user-1', name: 'Noble', email: 'noble@example.com' } },
        isPending: false,
        error: null,
        refetch: vi.fn(),
      }),
    })

    render(<AuthGate auth={auth}>{(user) => <p>Welcome {user.name}</p>}</AuthGate>)

    expect(screen.getByText('Welcome Noble')).toBeInTheDocument()
  })
})

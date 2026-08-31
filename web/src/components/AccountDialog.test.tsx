import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AccountDialog, type AccountBridge } from './AccountDialog'

function bridge(overrides: Partial<AccountBridge> = {}): AccountBridge {
  return {
    listAccounts: vi.fn(async () => [{ id: 'apple-account', providerId: 'apple' }]),
    linkProvider: vi.fn(async () => ({})),
    unlinkAccount: vi.fn(async () => ({})),
    ...overrides,
  }
}

describe('account dialog', () => {
  afterEach(cleanup)

  it('shows connected providers and starts explicit linking for another provider', async () => {
    const auth = bridge()
    render(<AccountDialog auth={auth} lastUsed="apple" onClose={vi.fn()} />)

    expect(await screen.findByText('Apple')).toBeInTheDocument()
    expect(screen.getByText('Connected')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Link Google' }))

    await waitFor(() => expect(auth.linkProvider).toHaveBeenCalledWith('google'))
  })

  it('never offers to remove the only sign-in method', async () => {
    render(<AccountDialog auth={bridge()} lastUsed="apple" onClose={vi.fn()} />)

    expect(await screen.findByText('Apple')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Remove Apple' })).not.toBeInTheDocument()
  })

  it('can remove one provider when another sign-in method remains', async () => {
    const unlinkAccount = vi.fn(async () => ({}))
    const auth = bridge({
      listAccounts: vi.fn(async () => [
        { id: 'apple-account', providerId: 'apple' },
        { id: 'google-account', providerId: 'google' },
      ]),
      unlinkAccount,
    })
    render(<AccountDialog auth={auth} lastUsed="google" onClose={vi.fn()} />)

    fireEvent.click(await screen.findByRole('button', { name: 'Remove Apple' }))

    await waitFor(() => expect(unlinkAccount).toHaveBeenCalledWith('apple-account'))
  })

  it('uses a flush close control with no container styling hook', () => {
    render(<AccountDialog auth={bridge()} lastUsed={null} onClose={vi.fn()} />)

    expect(screen.getByRole('button', { name: 'Close account settings' })).toHaveClass('account-dialog-close')
  })
})

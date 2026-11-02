import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { AI_CONSENT_FAILED, AiConsentDialog, PRIVACY_POLICY_URL } from './AiConsent'

afterEach(cleanup)

function deferred() {
  let resolve!: () => void
  let reject!: (reason: unknown) => void
  const promise = new Promise<void>((res, rej) => {
    resolve = res
    reject = rej
  })
  return { promise, resolve, reject }
}

describe('AiConsentDialog', () => {
  it('shows the plan copy, the privacy policy in a new tab, and the two answers', () => {
    render(<AiConsentDialog onAgree={vi.fn(async () => {})} onNotNow={vi.fn()} />)
    const dialog = screen.getByRole('dialog', { name: 'Before your first mix' })
    expect(dialog).toHaveTextContent(
      'Mixtape’s DJ runs on Anthropic’s Claude. To make your mixes we send it what you type or say, and the music and listening history you add. Voice clips are transcribed by Groq. Your data is not sold or used for ads.',
    )
    const link = screen.getByRole('link', { name: 'Privacy policy' })
    expect(link).toHaveAttribute('href', 'https://miixtape.netlify.app/privacy/')
    expect(PRIVACY_POLICY_URL).toBe('https://miixtape.netlify.app/privacy/')
    expect(link).toHaveAttribute('target', '_blank')
    expect(link).toHaveAttribute('rel', expect.stringContaining('noopener'))
    expect(screen.getByRole('button', { name: 'Agree and continue' })).toBeEnabled()
    expect(screen.getByRole('button', { name: 'Not now' })).toBeEnabled()
  })

  it('puts focus on Not now when it opens', () => {
    render(<AiConsentDialog onAgree={vi.fn(async () => {})} onNotNow={vi.fn()} />)
    expect(screen.getByRole('button', { name: 'Not now' })).toHaveFocus()
  })

  it('calls onAgree once and holds both answers while it runs', async () => {
    const pending = deferred()
    const onAgree = vi.fn(() => pending.promise)
    const onNotNow = vi.fn()
    render(<AiConsentDialog onAgree={onAgree} onNotNow={onNotNow} />)

    fireEvent.click(screen.getByRole('button', { name: 'Agree and continue' }))
    fireEvent.click(screen.getByRole('button', { name: 'Agree and continue' }))
    expect(onAgree).toHaveBeenCalledOnce()
    expect(screen.getByRole('button', { name: 'Agree and continue' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Not now' })).toBeDisabled()
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(onNotNow).not.toHaveBeenCalled()

    await act(async () => pending.resolve())
  })

  it('says so inline when the answer cannot be saved, and lets the listener try again', async () => {
    const onAgree = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(undefined)
    render(<AiConsentDialog onAgree={onAgree} onNotNow={vi.fn()} />)

    fireEvent.click(screen.getByRole('button', { name: 'Agree and continue' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t save that. Try again.')
    expect(AI_CONSENT_FAILED).toBe('Couldn’t save that. Try again.')
    expect(screen.getByRole('button', { name: 'Agree and continue' })).toBeEnabled()

    fireEvent.click(screen.getByRole('button', { name: 'Agree and continue' }))
    await waitFor(() => expect(onAgree).toHaveBeenCalledTimes(2))
    await waitFor(() => expect(screen.queryByRole('alert')).not.toBeInTheDocument())
  })

  it('answers Not now from the button and from Escape', () => {
    const onNotNow = vi.fn()
    const onAgree = vi.fn(async () => {})
    render(<AiConsentDialog onAgree={onAgree} onNotNow={onNotNow} />)
    fireEvent.click(screen.getByRole('button', { name: 'Not now' }))
    fireEvent.keyDown(document, { key: 'Escape' })
    expect(onNotNow).toHaveBeenCalledTimes(2)
    expect(onAgree).not.toHaveBeenCalled()
  })
})

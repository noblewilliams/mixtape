import { act, cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { InstallAppRow, installHint, resetInstallPromptForTest } from './install-app'

function promptEvent(outcome: 'accepted' | 'dismissed' = 'accepted') {
  const event = new Event('beforeinstallprompt') as Event & { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> }
  event.prompt = vi.fn(async () => {})
  event.userChoice = Promise.resolve({ outcome })
  return event
}

afterEach(() => { cleanup(); resetInstallPromptForTest() })

describe('installHint', () => {
  it('walks iOS Safari through Add to Home Screen', () => {
    expect(installHint('Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1'))
      .toBe('In Safari, tap Share, then Add to Home Screen.')
  })

  it('has nothing to say on a desktop browser', () => {
    expect(installHint('Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/140.0 Safari/537.36')).toBeNull()
  })
})

describe('InstallAppRow', () => {
  it('stays hidden when the browser offers no install path', () => {
    const { container } = render(<InstallAppRow userAgent="Mozilla/5.0 (Macintosh) Chrome/140.0" />)
    expect(container).toBeEmptyDOMElement()
  })

  it('offers the browser install prompt once one is available', async () => {
    render(<InstallAppRow userAgent="Mozilla/5.0 (Linux; Android 15) Chrome/140.0 Mobile" />)
    const event = promptEvent()
    act(() => { window.dispatchEvent(event) })
    await act(async () => { fireEvent.click(screen.getByRole('button', { name: 'Install' })) })
    expect(event.prompt).toHaveBeenCalled()
    expect(screen.queryByRole('button', { name: 'Install' })).not.toBeInTheDocument()
  })

  it('shows the Safari steps on an iPhone', () => {
    render(<InstallAppRow userAgent="Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) Version/18.0 Mobile Safari/604.1" />)
    expect(screen.getByText('Install Mixtape')).toBeInTheDocument()
    expect(screen.getByText('In Safari, tap Share, then Add to Home Screen.')).toBeInTheDocument()
  })

  it('disappears inside the installed app', () => {
    const { container } = render(<InstallAppRow standalone userAgent="Mozilla/5.0 (iPhone) Mobile Safari" />)
    expect(container).toBeEmptyDOMElement()
  })
})

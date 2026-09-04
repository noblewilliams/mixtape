import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { DjSession } from '../domain'
import { Conversation } from './Conversation'

const session: DjSession = {
  id: 'blue-hour',
  title: 'Blue hour, windows down',
  status: 'active',
  queueVersion: 3,
  notPersonal: false,
  updatedAt: '2026-08-31T12:00:00.000Z',
  ageLabel: 'a moment ago',
  trackCount: 15,
  durationLabel: '52 min',
  caseColor: '#544451',
}

describe('Conversation composer', () => {
  afterEach(cleanup)

  it('uses the approved straight-up arrow inside a separate visual surface', () => {
    render(
      <Conversation
        session={session}
        messages={[]}
        thinking={false}
        onSend={vi.fn()}
        onOpenQueue={vi.fn()}
      />,
    )

    const sendButton = screen.getByRole('button', { name: 'Send message' })
    const surface = sendButton.querySelector('.send-button-surface')

    expect(surface).toBeInTheDocument()
    expect(surface?.querySelector('path')).toHaveAttribute('d', 'M12 19V5M8 9l4-4 4 4')
  })

  it('retains the accessible send behavior', () => {
    const onSend = vi.fn()
    render(
      <Conversation
        session={session}
        messages={[]}
        thinking={false}
        onSend={onSend}
        onOpenQueue={vi.fn()}
      />,
    )

    const sendButton = screen.getByRole('button', { name: 'Send message' })
    expect(sendButton).toBeDisabled()

    fireEvent.change(screen.getByRole('textbox', { name: 'Message your DJ' }), {
      target: { value: 'Make the middle brighter.' },
    })
    fireEvent.click(sendButton)

    expect(onSend).toHaveBeenCalledWith('Make the middle brighter.')
  })
})

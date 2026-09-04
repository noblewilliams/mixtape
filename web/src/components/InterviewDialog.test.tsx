import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { InterviewResponse } from '../api/client'
import { createFakeApi } from '../test/fake-api'
import { InterviewDialog } from './InterviewDialog'

function renderDialog(options: { api?: ReturnType<typeof createFakeApi> } = {}) {
  const api = options.api ?? createFakeApi()
  const onClose = vi.fn()
  const onComplete = vi.fn()
  render(<InterviewDialog api={api} onClose={onClose} onComplete={onComplete} />)
  return { api, onClose, onComplete }
}

function addArtist(name: string) {
  const input = screen.getByLabelText('Artist')
  fireEvent.change(input, { target: { value: name } })
  fireEvent.keyDown(input, { key: 'Enter' })
}

describe('InterviewDialog', () => {
  afterEach(cleanup)

  it('opens on the artists step with the stepper and Back disabled', () => {
    renderDialog()

    expect(screen.getByRole('dialog', { name: 'Artists you would never skip' })).toBeInTheDocument()
    expect(screen.getByText('Tell the DJ about your taste · 1 of 5')).toBeInTheDocument()
    expect(screen.getByText('Type a name and press Enter. Up to 20.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Back' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Close interview' })).toBeInTheDocument()
    expect(document.querySelectorAll('.stepper span')).toHaveLength(5)
    expect(document.querySelectorAll('.stepper span.on')).toHaveLength(1)
  })

  it('requires at least one artist before moving on', () => {
    renderDialog()

    expect(screen.getByRole('button', { name: 'Next' })).toBeDisabled()
    addArtist('Ivory Kestrel')
    expect(screen.getByRole('button', { name: 'Remove Ivory Kestrel' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Next' })).toBeEnabled()

    fireEvent.click(screen.getByRole('button', { name: 'Remove Ivory Kestrel' }))
    expect(screen.getByRole('button', { name: 'Next' })).toBeDisabled()
  })

  it('caps artists at 20 and ignores duplicates', () => {
    renderDialog()

    for (let index = 0; index < 22; index += 1) addArtist(`Artist ${index}`)
    addArtist('Artist 3')

    expect(screen.getAllByRole('button', { name: /^Remove Artist/ })).toHaveLength(20)
  })

  it('walks the five steps with a 300-character counter and Finish on the last', () => {
    renderDialog()
    addArtist('Ivory Kestrel')
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))

    expect(screen.getByRole('dialog', { name: 'What do you play most these days?' })).toBeInTheDocument()
    expect(screen.getByText('Tell the DJ about your taste · 2 of 5')).toBeInTheDocument()
    const playsMost = screen.getByLabelText('Plays most')
    expect(playsMost).toHaveAttribute('maxlength', '300')
    fireEvent.change(playsMost, { target: { value: 'Mostly late-night radio edits.' } })
    expect(screen.getByText('30 / 300')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    expect(screen.getByRole('dialog', { name: 'When do you listen, and to what?' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    expect(screen.getByRole('dialog', { name: 'Anything you never want to hear?' })).toBeInTheDocument()
    expect(screen.getByText('Genres, moods, explicit lyrics, a specific artist. Say it plainly; the DJ treats it as a rule.')).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    expect(screen.getByRole('dialog', { name: 'An era you keep returning to?' })).toBeInTheDocument()
    expect(screen.getByText('Tell the DJ about your taste · 5 of 5')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Finish' })).toBeInTheDocument()
    expect(document.querySelectorAll('.stepper span.on')).toHaveLength(5)

    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    expect(screen.getByRole('dialog', { name: 'Anything you never want to hear?' })).toBeInTheDocument()
  })

  it('submits every answer with the web surface and reports the saved counts', async () => {
    const response: InterviewResponse = { seeds: 2, notes: { saved: 3, duplicate: 0, capped: 0 } }
    const postInterview = vi.fn(async () => response)
    const { onComplete } = renderDialog({ api: createFakeApi({ postInterview }) })

    addArtist('Ivory Kestrel')
    addArtist('Juniper North')
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    fireEvent.change(screen.getByLabelText('Plays most'), { target: { value: 'Quiet piano records.' } })
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    fireEvent.change(screen.getByLabelText('Listens when'), { target: { value: 'Cooking, most evenings.' } })
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    fireEvent.change(screen.getByLabelText('Era'), { target: { value: 'Late nineties.' } })
    fireEvent.click(screen.getByRole('button', { name: 'Finish' }))

    await waitFor(() => expect(onComplete).toHaveBeenCalledWith(response))
    expect(postInterview).toHaveBeenCalledWith({
      surface: 'web',
      neverSkip: ['Ivory Kestrel', 'Juniper North'],
      playsMost: 'Quiet piano records.',
      listensWhen: 'Cooking, most evenings.',
      neverWants: '',
      era: 'Late nineties.',
    })
  })

  it('keeps the dialog open with an error when saving fails', async () => {
    const postInterview = vi.fn(async () => {
      throw new Error('offline')
    })
    const { onComplete } = renderDialog({ api: createFakeApi({ postInterview }) })

    addArtist('Ivory Kestrel')
    for (let step = 0; step < 4; step += 1) fireEvent.click(screen.getByRole('button', { name: 'Next' }))
    fireEvent.click(screen.getByRole('button', { name: 'Finish' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('The DJ couldn’t save your answers. Try again.')
    expect(onComplete).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: 'Finish' })).toBeEnabled()
  })
})

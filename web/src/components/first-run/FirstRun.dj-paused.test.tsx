import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import { ApiError } from '../../api/client'
import { DJ_PAUSED_DETAIL, DJ_PAUSED_LINE } from '../../lib/dj-status'
import { fakeServices } from '../../test/first-run-fakes'
import { FirstRun } from './FirstRun'

const heading = (name: string) => screen.findByRole('heading', { level: 1, name })

beforeEach(() => window.history.replaceState(null, '', '/'))
afterEach(() => {
  cleanup()
  document.title = ''
})

describe('first run while the DJ is paused', () => {
  it('a mix refused with dj_paused comes back with no error, the prompt kept and the field off', async () => {
    const fakes = fakeServices()
    fakes.api.createSession.mockRejectedValueOnce(new ApiError(503, { error: 'dj_paused' }))
    render(<FirstRun services={fakes.services} onDone={vi.fn()} />)
    // Still nothing read on load.
    expect(fakes.api.getConfig).not.toHaveBeenCalled()

    fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: 'late night drive' } })
    fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
    await heading('Who do you love?')
    fireEvent.click(screen.getByRole('button', { name: 'Skip for now' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Agree and continue' }))

    await waitFor(() => expect(fakes.api.createSession).toHaveBeenCalledOnce())
    await heading('Who do you love?')
    expect(screen.queryByText(/Couldn’t make your mix/)).not.toBeInTheDocument()

    act(() => window.history.back())
    await heading('What do you want to hear?')
    const input = screen.getByRole('textbox', { name: 'Describe your mix' })
    expect(input).toBeDisabled()
    expect(input).toHaveValue('late night drive')
    expect(screen.getByText(`${DJ_PAUSED_LINE}. ${DJ_PAUSED_DETAIL}`)).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Make a mix' })).toBeDisabled()
  })
})

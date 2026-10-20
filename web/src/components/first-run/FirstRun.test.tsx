import { act, cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'
import type { AuthPreferenceStore } from '../../lib/auth-provider'
import { AnonymousCapError } from '../../api/client'
import { createdSession, fakeServices, syncResult } from '../../test/first-run-fakes'
import { FirstRun, type FirstRunProps } from './FirstRun'

const preferences: AuthPreferenceStore = {
  lastUsed: () => null,
  begin: vi.fn(),
  promotePending: () => null,
  clearPending: vi.fn(),
}

function renderFlow(props: Partial<FirstRunProps> = {}) {
  const fakes = fakeServices()
  const onDone = vi.fn()
  render(
    <FirstRun
      services={fakes.services}
      signIn={{ auth: { signIn: vi.fn(async () => ({})) }, preferences, lastUsed: null, error: '' }}
      onDone={onDone}
      {...props}
    />,
  )
  return { ...fakes, onDone }
}

/** onDone carries the whole createSession response. */
const madeMix = { session: createdSession('session-new') }

const heading = (name: string) => screen.findByRole('heading', { level: 1, name })

function typePrompt(text: string) {
  fireEvent.change(screen.getByRole('textbox', { name: 'Describe your mix' }), { target: { value: text } })
  fireEvent.click(screen.getByRole('button', { name: 'Make a mix' }))
}

function nameArtists(...names: string[]) {
  const labels = ['First artist', 'Second artist', 'Third artist']
  names.forEach((name, index) => fireEvent.change(screen.getByRole('textbox', { name: labels[index] }), { target: { value: name } }))
}

beforeEach(() => window.history.replaceState(null, '', '/'))
afterEach(() => {
  cleanup()
  document.title = ''
})

describe('path A, make a mix now', () => {
  it('asks for artists after the first prompt, then saves them and makes the mix with one session', async () => {
    const { onDone, log, ensureSession } = renderFlow()
    expect(await heading('What do you want to hear?')).toBeInTheDocument()
    expect(ensureSession).not.toHaveBeenCalled()

    typePrompt('something for a rainy commute, no talking')
    expect(await heading('Who do you love?')).toBeInTheDocument()
    expect(ensureSession).not.toHaveBeenCalled()

    nameArtists('Burna Boy', 'Tems', 'Sade')
    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))

    await waitFor(() => expect(onDone).toHaveBeenCalledWith(madeMix))
    expect(ensureSession).toHaveBeenCalledOnce()
    expect(log).toEqual([
      'ensureSession',
      'putArtistSeeds:Burna Boy|Tems|Sade',
      'createSession:something for a rainy commute, no talking',
    ])
  })

  it('keeps the artists page and says so when the seeds cannot be saved', async () => {
    const { api, onDone } = renderFlow()
    api.putArtistSeeds.mockRejectedValueOnce(new Error('offline'))
    typePrompt('late night drive')
    await heading('Who do you love?')
    nameArtists('Burna Boy', 'Tems', 'Sade')
    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t save your artists. Try again.')
    expect(api.createSession).not.toHaveBeenCalled()
    expect(onDone).not.toHaveBeenCalled()
  })

  it('shows no counter or progress line on path A pages', async () => {
    renderFlow()
    await heading('What do you want to hear?')
    expect(screen.queryByTestId('fr-progress')).not.toBeInTheDocument()
    typePrompt('late night drive')
    await heading('Who do you love?')
    expect(screen.queryByTestId('fr-progress')).not.toBeInTheDocument()
    expect(screen.queryByText(/Step \d of 3/)).not.toBeInTheDocument()
  })

  it('opens the existing sign-in page from the foot link', async () => {
    renderFlow()
    fireEvent.click(screen.getByRole('button', { name: 'Sign in.' }))
    expect(await screen.findByRole('button', { name: 'Continue with Apple' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Continue with Google' })).toBeInTheDocument()
    expect(document.title).toBe('Your music, mixed for right now.')
  })

  it('starts on the sign-in page when a sign-in came back with an error', () => {
    const fakes = fakeServices()
    render(
      <FirstRun
        services={fakes.services}
        signIn={{ auth: { signIn: vi.fn(async () => ({})) }, preferences, lastUsed: null, error: 'Apple sign-in did not finish.' }}
        onDone={vi.fn()}
      />,
    )
    expect(screen.getByRole('alert')).toHaveTextContent('Apple sign-in did not finish.')
  })
})

describe('the first mix failing', () => {
  it.each([
    ['a network error', new TypeError('Failed to fetch')],
    ['the anonymous cap', new AnonymousCapError({ error: 'anonymous_cap', limit: 3 })],
  ])('keeps the prompt and says so after %s', async (_label, failure) => {
    const { api, onDone } = renderFlow()
    api.createSession.mockRejectedValueOnce(failure)
    typePrompt('late night drive')
    await heading('Who do you love?')
    nameArtists('Burna Boy', 'Tems', 'Sade')
    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t make your mix. Try again.')
    expect(onDone).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: 'Continue' })).toBeEnabled()

    act(() => window.history.back())
    expect(await heading('What do you want to hear?')).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('late night drive')
  })

  it('keeps the prompt on the prompt page when the mix fails there', async () => {
    const { api, onDone } = renderFlow()
    api.createSession.mockRejectedValueOnce(new AnonymousCapError({ error: 'anonymous_cap' }))
    fireEvent.click(screen.getByRole('button', { name: 'Add my music first' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Skip for now' }))
    await heading('Who do you love?')
    nameArtists('Burna Boy', 'Tems', 'Sade')
    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))
    await heading('What do you want to hear?')
    typePrompt('warm up for a long run')

    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t make your mix. Try again.')
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('warm up for a long run')
    expect(onDone).not.toHaveBeenCalled()
  })
})

describe('path B, add my music first', () => {
  async function toStep1() {
    const fakes = renderFlow()
    fireEvent.click(screen.getByRole('button', { name: 'Add my music first' }))
    await heading('Step 1 of 3, Which do you use?')
    return fakes
  }

  it('counts the three steps, in the heading and the title', async () => {
    await toStep1()
    expect(document.title).toBe('Step 1 of 3, Which do you use?')
    expect(screen.getByTestId('fr-progress')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Spotify' }))
    expect(await heading('Step 2 of 3, How do you want to add it?')).toBeInTheDocument()
    expect(document.title).toBe('Step 2 of 3, How do you want to add it?')

    fireEvent.click(screen.getByRole('button', { name: 'Spotify data export, a few days' }))
    expect(await heading('Step 3 of 3, Request your data')).toBeInTheDocument()
    expect(document.title).toBe('Step 3 of 3, Request your data')
  })

  it('moves focus to the heading on each page change', async () => {
    await toStep1()
    expect(screen.getByRole('heading', { level: 1, name: 'Step 1 of 3, Which do you use?' })).toHaveFocus()
    fireEvent.click(screen.getByRole('button', { name: 'Apple Music' }))
    expect(await heading('Step 2 of 3, How do you want to add it?')).toHaveFocus()
  })

  it('Skip for now goes to Who do you love?, then the prompt page after the seeds', async () => {
    const { log, onDone } = await toStep1()
    fireEvent.click(screen.getByRole('button', { name: 'Skip for now' }))
    expect(await heading('Who do you love?')).toBeInTheDocument()

    nameArtists('Burna Boy', 'Tems', 'Sade')
    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))
    expect(await heading('What do you want to hear?')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Add my music first' })).not.toBeInTheDocument()

    typePrompt('warm up for a long run')
    await waitFor(() => expect(onDone).toHaveBeenCalledWith(madeMix))
    expect(log).toEqual(['ensureSession', 'putArtistSeeds:Burna Boy|Tems|Sade', 'ensureSession', 'createSession:warm up for a long run'])
  })

  it('syncs Apple Music after making sure of the session, then asks with the count', async () => {
    const { syncRun, ensureSession, onDone, api } = await toStep1()
    fireEvent.click(screen.getByRole('button', { name: 'Apple Music' }))
    await heading('Step 2 of 3, How do you want to add it?')
    expect(ensureSession).not.toHaveBeenCalled()

    fireEvent.click(screen.getByRole('button', { name: 'Sync my library' }))
    expect(await heading('Step 3 of 3, Syncing your library')).toBeInTheDocument()
    await waitFor(() => expect(syncRun.start).toHaveBeenCalledOnce())
    expect(ensureSession.mock.invocationCallOrder[0]).toBeLessThan(syncRun.start.mock.invocationCallOrder[0])

    act(() => syncRun.set(syncResult(1284)))
    fireEvent.click(screen.getByRole('button', { name: 'Done' }))

    expect(await heading('What do you want to hear?')).toBeInTheDocument()
    expect(screen.getByText('1,284 songs in. Ask for anything.')).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Add my music first' })).not.toBeInTheDocument()
    expect(screen.queryByTestId('fr-progress')).not.toBeInTheDocument()

    typePrompt('90s R&B, no ballads')
    await waitFor(() => expect(onDone).toHaveBeenCalledWith(madeMix))
    expect(api.putArtistSeeds).not.toHaveBeenCalled()
  })

  it('puts Who do you love? before the prompt page when the sync brought nothing usable', async () => {
    const { syncRun } = await toStep1()
    fireEvent.click(screen.getByRole('button', { name: 'Apple Music' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Sync my library' }))
    await heading('Step 3 of 3, Syncing your library')
    act(() => syncRun.set(syncResult(0)))
    fireEvent.click(screen.getByRole('button', { name: 'Done' }))

    expect(await heading('Who do you love?')).toBeInTheDocument()
    nameArtists('Burna Boy', 'Tems', 'Sade')
    fireEvent.click(screen.getByRole('button', { name: 'Continue' }))
    expect(await heading('What do you want to hear?')).toBeInTheDocument()
  })

  it('continues with what came in after a failed sync', async () => {
    const { syncRun } = await toStep1()
    fireEvent.click(screen.getByRole('button', { name: 'Apple Music' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Sync my library' }))
    await heading('Step 3 of 3, Syncing your library')
    act(() => syncRun.set({ kind: 'running', progress: { stage: 'library_songs', completed: 612 } }))
    act(() => syncRun.set({ kind: 'error', failure: 'connection' }))
    fireEvent.click(screen.getByRole('button', { name: "Continue with what’s in" }))

    expect(await screen.findByText('612 songs in. Ask for anything.')).toBeInTheDocument()
  })

  it('goes to Who do you love? after the Spotify request is recorded', async () => {
    const { log } = await toStep1()
    fireEvent.click(screen.getByRole('button', { name: 'Spotify' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Spotify data export, a few days' }))
    fireEvent.click(await screen.findByRole('button', { name: "I’ve requested it" }))

    expect(await heading('Who do you love?')).toBeInTheDocument()
    expect(log).toEqual(['ensureSession', 'postFunnelEvent:marked_requested'])
  })
})

describe('history', () => {
  it('folds the flow\'s entries back when it finishes', async () => {
    const go = vi.spyOn(window.history, 'go')
    try {
      const { onDone } = renderFlow()
      typePrompt('late night drive')
      await heading('Who do you love?')
      nameArtists('Burna Boy', 'Tems', 'Sade')
      fireEvent.click(screen.getByRole('button', { name: 'Continue' }))
      await waitFor(() => expect(onDone).toHaveBeenCalledWith(madeMix))
      expect(go).toHaveBeenCalledWith(-1)
    } finally {
      go.mockRestore()
    }
  })

  it('does not move focus to the heading on first load', () => {
    renderFlow()
    expect(screen.getByRole('heading', { level: 1, name: 'What do you want to hear?' })).not.toHaveFocus()
  })

  it('pushes an entry per page, and back pops to the previous page', async () => {
    renderFlow()
    const start = window.history.length
    fireEvent.click(screen.getByRole('button', { name: 'Add my music first' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Spotify' }))
    await heading('Step 2 of 3, How do you want to add it?')
    expect(window.history.length).toBe(start + 2)

    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    expect(await heading('Step 1 of 3, Which do you use?')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    expect(await heading('What do you want to hear?')).toBeInTheDocument()
    expect(document.title).toBe('What do you want to hear?')
  })

  it('answers the browser back the same way and keeps what was typed', async () => {
    renderFlow()
    typePrompt('late night drive')
    await heading('Who do you love?')
    act(() => window.history.back())
    expect(await heading('What do you want to hear?')).toBeInTheDocument()
    expect(screen.getByRole('textbox', { name: 'Describe your mix' })).toHaveValue('late night drive')
  })
})

describe('Library add flow', () => {
  function renderAdd() {
    const fakes = fakeServices()
    const onDone = vi.fn()
    const onChooseService = vi.fn()
    render(<FirstRun mode="add" services={fakes.services} onChooseService={onChooseService} onDone={onDone} />)
    return { ...fakes, onDone, onChooseService }
  }

  it('moves focus to the Step 1 heading when it opens over the shell', () => {
    renderAdd()
    expect(screen.getByRole('heading', { level: 1, name: 'Step 1 of 3, Which do you use?' })).toHaveFocus()
  })

  it('opens on Step 1 and returns to Library after the request', async () => {
    const { onDone, onChooseService } = renderAdd()
    expect(screen.getByRole('heading', { level: 1, name: 'Step 1 of 3, Which do you use?' })).toHaveFocus()
    expect(screen.queryByRole('heading', { name: 'What do you want to hear?' })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Spotify' }))
    expect(onChooseService).toHaveBeenCalledWith('spotify')
    fireEvent.click(await screen.findByRole('button', { name: 'Spotify data export, a few days' }))
    fireEvent.click(await screen.findByRole('button', { name: "I’ve requested it" }))

    await waitFor(() => expect(onDone).toHaveBeenCalledWith({}))
    expect(screen.queryByRole('heading', { name: 'Who do you love?' })).not.toBeInTheDocument()
    expect(onChooseService).toHaveBeenCalledTimes(1)
  })

  it('returns to Library after an Apple sync instead of the prompt page', async () => {
    const { onDone, syncRun } = renderAdd()
    fireEvent.click(screen.getByRole('button', { name: 'Apple Music' }))
    fireEvent.click(await screen.findByRole('button', { name: 'Sync my library' }))
    await waitFor(() => expect(syncRun.start).toHaveBeenCalled())
    act(() => syncRun.set(syncResult(40)))
    fireEvent.click(screen.getByRole('button', { name: 'Done' }))
    expect(onDone).toHaveBeenCalledWith({})
  })

  it('leaves with Skip for now or back from Step 1', async () => {
    const first = renderAdd()
    fireEvent.click(screen.getByRole('button', { name: 'Skip for now' }))
    expect(first.onDone).toHaveBeenCalledWith({})
    cleanup()

    const second = renderAdd()
    fireEvent.click(screen.getByRole('button', { name: 'Back' }))
    await waitFor(() => expect(second.onDone).toHaveBeenCalledWith({}))
  })
})

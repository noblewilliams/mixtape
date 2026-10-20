import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { fakeServices, syncResult } from '../../test/first-run-fakes'
import { DoingPage } from './DoingPage'
import type { AddMethod } from './ChooseMethod'
import { importRunWithSession } from './services'
import { ApiError } from '../../api/client'
import { createImportRun } from '../../import/import-run'
import { createListeningImportService } from '../../import/import-service'
import { createDirectParser } from '../../import/direct-parser'
import { createFakeApi } from '../../test/fake-api'

const EXPORTIFY_CSV = 'Track URI,Track Name,Artist Name(s),Album Name,Duration (ms),Added At\nspotify:track:GlassCorridor000000001,Glass Corridor,Synthetic Artist,Synthetic Album,200000,2026-01-01T00:00:00Z\n'

function renderDoing(method: AddMethod, overrides: Partial<Parameters<typeof DoingPage>[0]> = {}) {
  const fakes = fakeServices()
  const props = {
    method,
    services: fakes.services,
    onBack: vi.fn(),
    onStartSync: vi.fn(),
    onSynced: vi.fn(),
    onImported: vi.fn(),
    onRequested: vi.fn(),
    ...overrides,
  }
  const view = render(<DoingPage {...props} />)
  return { ...fakes, props, view }
}

describe('Step 3 of 3, Apple sync', () => {
  afterEach(cleanup)

  it('counts songs as they arrive with Done waiting', () => {
    const { syncRun, view } = renderDoing('apple-sync')
    act(() => syncRun.set({ kind: 'running', progress: { stage: 'library_songs', completed: 612 } }))

    expect(screen.getByRole('heading', { level: 1, name: 'Step 3 of 3, Syncing your library' })).toBeInTheDocument()
    expect(screen.getByText('612 songs so far', { selector: '.fr-status' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Done' })).toBeDisabled()
    expect(screen.queryByRole('button', { name: 'Retry' })).not.toBeInTheDocument()
    expect(screen.getByTestId('fr-progress').style.width).toBe('100%')
    expect(view.container.querySelector('.cassette--loading')).not.toBeNull()
    expect((view.container.querySelector('.fr-page') as HTMLElement).dataset.background).toBe('step-3')
  })

  it('announces progress as a polite status, at most every ten seconds', () => {
    vi.useFakeTimers({ toFake: ['Date'] })
    try {
      const { syncRun } = renderDoing('apple-sync')
      act(() => syncRun.set({ kind: 'running', progress: { stage: 'library_songs', completed: 100 } }))
      expect(screen.getByRole('status')).toHaveTextContent('100 songs so far')
      act(() => syncRun.set({ kind: 'running', progress: { stage: 'library_songs', completed: 300 } }))
      expect(screen.getByRole('status')).toHaveTextContent('100 songs so far')
      vi.setSystemTime(Date.now() + 10_000)
      act(() => syncRun.set({ kind: 'running', progress: { stage: 'library_songs', completed: 612 } }))
      expect(screen.getByRole('status')).toHaveTextContent('612 songs so far')
    } finally {
      vi.useRealTimers()
    }
  })

  it('ends with the count in and Done ready', () => {
    const { syncRun, props } = renderDoing('apple-sync')
    act(() => syncRun.set({ kind: 'running', progress: { stage: 'library_songs', completed: 612 } }))
    act(() => syncRun.set(syncResult(1284)))

    expect(screen.getAllByText('1,284 songs in.').length).toBeGreaterThan(0)
    fireEvent.click(screen.getByRole('button', { name: 'Done' }))
    expect(props.onSynced).toHaveBeenCalledWith(1284)
  })

  it('keeps the count on failure and offers Retry and Continue with what\'s in', () => {
    const { syncRun, props, view } = renderDoing('apple-sync')
    act(() => syncRun.set({ kind: 'running', progress: { stage: 'library_songs', completed: 612 } }))
    act(() => syncRun.set({ kind: 'error', failure: 'connection' }))

    expect(screen.getByRole('alert')).toHaveTextContent('Sync stopped at 612 songs.')
    expect(view.container.querySelector('.cassette--loading')).toBeNull()
    fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
    expect(props.onStartSync).toHaveBeenCalledOnce()
    fireEvent.click(screen.getByRole('button', { name: "Continue with what’s in" }))
    expect(props.onSynced).toHaveBeenCalledWith(612)
  })

  it('treats a sync that could not start as stopped', () => {
    renderDoing('apple-sync', { syncStartFailed: true })
    expect(screen.getByRole('alert')).toHaveTextContent('Sync stopped at 0 songs.')
  })
})

describe('Step 3 of 3, Exportify', () => {
  afterEach(cleanup)

  it('shows the existing three lines, Open Exportify, and the existing file import', () => {
    renderDoing('exportify')

    expect(screen.getByRole('heading', { level: 1, name: 'Step 3 of 3, Export from Exportify' })).toBeInTheDocument()
    expect(screen.getAllByRole('listitem')).toHaveLength(3)
    expect(screen.getByText('Open Exportify and connect Spotify.')).toBeInTheDocument()
    const link = screen.getByRole('link', { name: 'Open Exportify (opens outside Mixtape)' })
    expect(link).toHaveAttribute('href', 'https://exportify.app/')
    expect(link).toHaveAttribute('target', '_blank')
    // B6: the pick step is a Choose files pill wrapping the file input.
    const region = screen.getByRole('region', { name: 'Import a Spotify ZIP' })
    const pill = within(region).getByText('Choose files').closest('label')
    expect(pill).toHaveClass('fr-pill', 'fr-pill--go')
    expect(pill?.querySelector('input[type="file"]')).toHaveAttribute('multiple')
    expect(screen.queryByText(/Exportify ZIP or CSV files/)).not.toBeInTheDocument()
  })

  it('reads a file dropped anywhere on the page', async () => {
    const { importRun, ensureSession } = renderDoing('exportify')
    const file = new File(['x'], 'export.zip', { type: 'application/zip' })
    const drop = new Event('drop', { bubbles: true, cancelable: true }) as Event & { dataTransfer: unknown }
    drop.dataTransfer = { files: [file] }
    act(() => { window.dispatchEvent(drop) })

    await waitFor(() => expect(importRun.take).toHaveBeenCalledWith(file))
    expect(ensureSession).toHaveBeenCalledOnce()
  })

  it('shows the existing review on paper once a file is read', () => {
    const { importRun, view } = renderDoing('exportify')
    act(() => importRun.set({ kind: 'read-failed', file: new File(['x'], 'export.zip') }))
    expect(view.container.querySelector('.fr-host .import-card')).not.toBeNull()
    expect(screen.queryByText('Choose files')).not.toBeInTheDocument()
  })
})

describe('Step 3 of 3, Spotify data export', () => {
  afterEach(cleanup)

  it('shows the existing request steps and records the request after making sure of the session', async () => {
    const { props, log } = renderDoing('spotify-export')

    expect(screen.getByRole('heading', { level: 1, name: 'Step 3 of 3, Request your data' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'spotify.com/account/privacy' })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: "I’ve requested it" }))

    await waitFor(() => expect(props.onRequested).toHaveBeenCalledOnce())
    expect(log).toEqual(['ensureSession', 'postFunnelEvent:marked_requested'])
  })

  it('keeps the page and says so when the request cannot be recorded', async () => {
    const { api, props } = renderDoing('spotify-export')
    api.postFunnelEvent.mockRejectedValueOnce(new Error('offline'))

    fireEvent.click(screen.getByRole('button', { name: "I’ve requested it" }))

    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t save that. Check your connection and try again.')
    expect(props.onRequested).not.toHaveBeenCalled()
    expect(screen.getByRole('button', { name: "I’ve requested it" })).toBeEnabled()
  })
})

describe('the import run inside the first run', () => {
  it('makes sure of the session before reading a picked file, and before an upload or retry', async () => {
    const { importRun, ensureSession } = fakeServices()
    const run = importRunWithSession(importRun, ensureSession, vi.fn())

    run.take(new File(['x'], 'a.zip'))
    await waitFor(() => expect(importRun.take).toHaveBeenCalledOnce())
    run.upload()
    run.retry()
    run.reviewAgain()
    run.tryAgain()
    await waitFor(() => expect(importRun.tryAgain).toHaveBeenCalledOnce())
    expect(importRun.upload).toHaveBeenCalledOnce()
    expect(importRun.retry).toHaveBeenCalledOnce()
    expect(importRun.reviewAgain).toHaveBeenCalledOnce()
    expect(ensureSession).toHaveBeenCalledTimes(5)
    expect(ensureSession.mock.invocationCallOrder[0]).toBeLessThan(vi.mocked(importRun.take).mock.invocationCallOrder[0])
  })

  it('reads an Exportify file against an API that refuses until a session exists', async () => {
    let session = false
    const refuse = () => {
      if (!session) throw new ApiError(401, { error: 'unauthorized' })
    }
    const api = createFakeApi({
      getSpotifyCollectionReview: async () => {
        refuse()
        return { library: { ids: [], fingerprint: '0'.repeat(64) }, playlists: [] }
      },
      postFunnelEvent: async () => {
        refuse()
        return { ok: true as const }
      },
    })
    const parser = createDirectParser()
    const real = createImportRun({ importService: createListeningImportService({ api, parser }), parser, onImported: () => undefined })
    const ensureSession = vi.fn(async () => {
      session = true
    })
    const run = importRunWithSession(real, ensureSession, vi.fn())

    run.take(new File([EXPORTIFY_CSV], 'liked.csv', { type: 'text/csv' }))

    await waitFor(() => expect(real.getState().kind).toBe('inventory'))
    expect(ensureSession).toHaveBeenCalledOnce()
    real.dispose()
  })

  it('without the session first, the same file fails to read', async () => {
    const api = createFakeApi({
      getSpotifyCollectionReview: async () => {
        throw new ApiError(401, { error: 'unauthorized' })
      },
    })
    const parser = createDirectParser()
    const real = createImportRun({ importService: createListeningImportService({ api, parser }), parser, onImported: () => undefined })

    real.take(new File([EXPORTIFY_CSV], 'liked.csv', { type: 'text/csv' }))

    await waitFor(() => expect(real.getState()).toMatchObject({ kind: 'read-failed', review: true }))
    real.dispose()
  })
})

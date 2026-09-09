import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ImportPanel, type ImportPanelHandle } from './ImportPanel'
import { ApiError, type MixtapeApi } from '../api/client'
import { createDirectParser } from '../import/direct-parser'
import { createImportRun } from '../import/import-run'
import { createListeningImportService } from '../import/import-service'
import type { PageParser } from '../import/page-parser'
import { parseExport } from '../import/spotify-parser'
import { openZipArchive } from '../import/zip-reader'
import { createFakeApi } from '../test/fake-api'
import { readExpected, readFixtureArchiveBytes } from '../test/listening-export-fixtures'
import { HISTORY_DIR, historyRow } from '../test/spotify-export-rows'
import { buildZipBlob } from '../test/zip-builder'
import { createUploadGate, type UploadGate } from '../sync/upload-gate'

function fixtureFile(caseName: string, fileName = `${caseName}.zip`): File {
  return new File([readFixtureArchiveBytes(caseName)], fileName, { type: 'application/zip' })
}

async function facts(caseName: string) {
  const { snapshot } = await parseExport(await openZipArchive(fixtureFile(caseName)), {
    timeZone: 'UTC',
    includePrivateSessions: false,
  })
  return snapshot
}

type Deferred = { release: () => void; held: Promise<void> }

function deferred(): Deferred {
  let release!: () => void
  const held = new Promise<void>((resolve) => {
    release = resolve
  })
  return { release, held }
}

/** The in-page parser with its parse held until released, for the reading and re-parse states. */
function heldParser(hold: (options: { includePrivateSessions: boolean }) => boolean = () => true) {
  const direct = createDirectParser()
  const gate = deferred()
  const signals: AbortSignal[] = []
  const parser: PageParser = {
    ...direct,
    parse: async (file, options) => {
      if (hold(options)) {
        if (options.signal) signals.push(options.signal)
        await gate.held
      }
      return direct.parse(file, options)
    },
  }
  return { parser, gate, signals }
}

function renderPanel(options: { overrides?: Partial<MixtapeApi>; parser?: PageParser; uploadGate?: UploadGate } = {}) {
  const api = createFakeApi(options.overrides)
  const parser = options.parser ?? createDirectParser()
  const importService = createListeningImportService({ api, parser })
  const onRefresh = vi.fn(async () => undefined)
  const run = createImportRun({ importService, parser, onImported: onRefresh, uploadGate: options.uploadGate })
  const onNewTape = vi.fn()
  const handle: { current: ImportPanelHandle | null } = { current: null }
  const view = render(<ImportPanel ref={handle} run={run} onNewTape={onNewTape} />)
  return { api, parser, run, onRefresh, onNewTape, handle, unmount: view.unmount }
}

function pick(file: File) {
  fireEvent.change(screen.getByLabelText('choose files'), { target: { files: [file] } })
}

const panel = () => screen.getByRole('region', { name: 'Import a Spotify ZIP' })
const chip = () => within(panel()).getByRole('status')

async function inventoryFor(caseName: string, fileName?: string, options?: Parameters<typeof renderPanel>[0]) {
  const rendered = renderPanel(options)
  pick(fixtureFile(caseName, fileName))
  await within(panel()).findByRole('button', { name: 'Upload' })
  return rendered
}

afterEach(cleanup)

describe('ImportPanel · pick', () => {
  it('allows local inspection but prevents uploading while Apple holds the shared gate', async () => {
    const uploadGate = createUploadGate()
    const release = uploadGate.acquire('apple')!
    const { run, api } = await inventoryFor('account-basic', undefined, { uploadGate })
    run.upload()
    expect(run.getState().kind).toBe('inventory')
    expect(api.calls.some((call) => call.method === 'beginListeningImport')).toBe(false)
    release()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))
    await waitFor(() => expect(run.getState().kind).toBe('done'))
    expect(uploadGate.getOwner()).toBeNull()
  })
  it('offers the drop zone with the board copy and a real file input', () => {
    renderPanel()
    const drop = panel()
    expect(drop).toHaveClass('drop')
    expect(drop).toHaveTextContent('Choose files')
    expect(drop).toHaveTextContent('or choose files · Exportify ZIP or CSV files, or an official Spotify ZIP')
    const input = screen.getByLabelText('choose files')
    expect(input).toHaveAttribute('type', 'file')
    expect(input).toHaveAttribute('accept', '.zip,.csv,application/zip,text/csv')
    expect(within(drop).queryByRole('status')).not.toBeInTheDocument()
  })

  it('highlights while a file is dragged over it and takes a dropped file', async () => {
    renderPanel()
    const drop = panel()
    fireEvent.dragOver(drop, { dataTransfer: { files: [], types: ['Files'] } })
    expect(drop).toHaveClass('drop--over')
    fireEvent.dragLeave(drop)
    expect(drop).not.toHaveClass('drop--over')

    fireEvent.drop(drop, { dataTransfer: { files: [fixtureFile('extended-basic')] } })
    expect(await within(panel()).findByRole('button', { name: 'Upload' })).toBeInTheDocument()
  })
})

describe('ImportPanel · inventory', () => {
  it('lists the facts for an extended package before anything is uploaded', async () => {
    const { api } = await inventoryFor('extended-basic', 'my_spotify_data_extended.zip')
    const snapshot = await facts('extended-basic')
    const expected = readExpected('extended-basic', 'default')
    const view = panel()

    expect(within(view).getByText('my_spotify_data_extended.zip')).toBeInTheDocument()
    expect(within(view).getByText(/^\d+(\.\d)? KB · Extended streaming history$/)).toBeInTheDocument()
    expect(chip()).toHaveTextContent('Readable')

    const terms = within(view).getAllByRole('term').map((term) => term.textContent)
    expect(terms).toEqual(['Tracks', 'Days with plays', 'Years', 'Local days in', 'Skipped rows'])
    const definitions = within(view).getAllByRole('definition').map((definition) => definition.textContent)
    expect(definitions).toEqual([
      String(snapshot.tracks.length),
      String(snapshot.days.length),
      `${snapshot.ledgerFrom!.slice(0, 4)} – ${snapshot.ledgerTo!.slice(0, 4)}`,
      'UTC',
      'None',
    ])

    const files = within(view).getAllByRole('listitem')
    expect(files.map((item) => item.textContent)).toEqual(
      expected.inventory.read.map((file) => file.path.slice(file.path.lastIndexOf('/') + 1)),
    )
    expect(files.every((item) => !item.classList.contains('ignored'))).toBe(true)

    const toggle = within(view).getByRole('switch', { name: 'Include private sessions' })
    expect(toggle).toHaveAttribute('aria-checked', 'false')
    const label = toggle.closest('label')!
    expect(label).toHaveClass('toggle')
    expect(label.control).toBe(toggle)
    expect(within(view).getByText('· No private-session plays in this file.')).toBeInTheDocument()
    fireEvent.click(within(label).getByText(/^Include private sessions/))
    expect(toggle).toHaveAttribute('aria-checked', 'true')
    fireEvent.click(toggle)
    expect(toggle).toHaveAttribute('aria-checked', 'false')
    expect(within(view).getByText('Only reviewed music leaves this device. Your account details, payments, and IP addresses are never read.')).toBeInTheDocument()
    expect(within(view).getByRole('button', { name: 'Upload' })).toBeInTheDocument()
    expect(within(view).getByRole('button', { name: 'Choose a different file' })).toBeInTheDocument()
    expect(api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => call.args[0])).toEqual([
      { type: 'file_inspected', surface: 'web' },
    ])
    expect(api.calls.some((call) => call.method === 'beginListeningImport')).toBe(false)
  })

  it('breaks skipped rows out by reason and says when no plays are private', async () => {
    await inventoryFor('extended-podcasts-and-local')
    const view = panel()
    const definitions = within(view).getAllByRole('definition').map((definition) => definition.textContent)
    expect(definitions[4]).toBe('3 podcasts · 3 local files')
    expect(within(view).getByRole('switch', { name: 'Include private sessions' })).toHaveAttribute('aria-checked', 'false')
    expect(within(view).getByText('· No private-session plays in this file.')).toBeInTheDocument()
    expect(within(view).queryByText(/hidden from followers/)).not.toBeInTheDocument()
  })

  it('counts the private plays the switch would add', async () => {
    await inventoryFor('extended-private-sessions')
    const view = panel()
    const definitions = within(view).getAllByRole('definition').map((definition) => definition.textContent)
    expect(definitions[4]).toBe('None')
    expect(
      within(view).getByText('· 4 plays hidden from followers stay out unless you choose otherwise.'),
    ).toBeInTheDocument()
  })

  it('uses singular forms and omits zero parts of the skipped-rows fact', async () => {
    const onePodcast = new File(
      [
        await buildZipBlob([
          {
            path: `${HISTORY_DIR}/Streaming_History_Audio_2025_0.json`,
            json: [
              historyRow(),
              historyRow({ spotify_episode_uri: 'spotify:episode:QuietWorkshopEp0000012' }),
              historyRow({ incognito_mode: true }),
            ],
          },
        ]),
      ],
      'one.zip',
      { type: 'application/zip' },
    )
    renderPanel()
    pick(onePodcast)
    await within(panel()).findByRole('button', { name: 'Upload' })
    const definitions = within(panel()).getAllByRole('definition').map((definition) => definition.textContent)
    expect(definitions[4]).toBe('1 podcast')
    expect(
      within(panel()).getByText('· 1 play hidden from followers stays out unless you choose otherwise.'),
    ).toBeInTheDocument()
    cleanup()

    const oneLocal = new File(
      [
        await buildZipBlob([
          {
            path: `${HISTORY_DIR}/Streaming_History_Audio_2025_0.json`,
            json: [historyRow(), historyRow({ spotify_track_uri: null })],
          },
        ]),
      ],
      'one.zip',
      { type: 'application/zip' },
    )
    renderPanel()
    pick(oneLocal)
    await within(panel()).findByRole('button', { name: 'Upload' })
    expect(within(panel()).getAllByRole('definition').map((definition) => definition.textContent)[4]).toBe('1 local file')
  })

  it('lists the facts for an account package with no private-sessions switch and the ignored file named', async () => {
    await inventoryFor('account-basic')
    const snapshot = await facts('account-basic')
    const view = panel()

    expect(within(view).getByText(/^\d+(\.\d)? KB · Account data$/)).toBeInTheDocument()
    const terms = within(view).getAllByRole('term').map((term) => term.textContent)
    expect(terms).toEqual(['Tracks', 'Liked songs', 'Artists', 'Playlists', 'Skipped rows'])
    const definitions = within(view).getAllByRole('definition').map((definition) => definition.textContent)
    expect(definitions).toEqual([
      String(snapshot.tracks.length),
      String(snapshot.library.length),
      String(snapshot.artists.length),
      String(snapshot.playlists.length),
      'None',
    ])
    expect(within(view).queryByRole('switch')).not.toBeInTheDocument()

    const ignored = within(view).getByText('StreamingHistory_music_0.json').closest('li')!
    expect(ignored).toHaveClass('ignored')
    expect(ignored).toHaveTextContent('ignored')
    expect(within(view).getByText('Playlist1.json').closest('li')).not.toHaveClass('ignored')
  })

  it('shows the sentinel files as ignored and never their contents', async () => {
    await inventoryFor('account-pii-present')
    const expected = readExpected('account-pii-present', 'default')
    const view = panel()

    for (const file of expected.inventory.ignored) {
      const name = file.path.slice(file.path.lastIndexOf('/') + 1)
      const item = within(view).getByText(name).closest('li')!
      expect(item).toHaveClass('ignored')
      expect(item).toHaveTextContent(`${name} ignored`)
    }
    expect(document.body.textContent).not.toContain('DO-NOT-READ')
  })

  it('goes back to the drop zone from Choose a different file and releases the parser', async () => {
    const parser = createDirectParser()
    const terminate = vi.spyOn(parser, 'terminate')
    await inventoryFor('extended-basic', undefined, { parser })
    fireEvent.click(within(panel()).getByRole('button', { name: 'Choose a different file' }))
    expect(panel()).toHaveClass('drop')
    expect(terminate).toHaveBeenCalled()
  })
})

describe('ImportPanel · upload', () => {
  it('uploads with live progress, then reports the summary and refreshes onboarding', async () => {
    const { api, onRefresh, onNewTape } = await inventoryFor('extended-basic')
    const snapshot = await facts('extended-basic')

    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))

    expect(await within(panel()).findByText('Extended history imported')).toBeInTheDocument()
    const view = panel()
    expect(chip()).toHaveTextContent('Done')
    expect(chip()).toHaveTextContent(`import complete, ${snapshot.tracks.length} tracks`)
    const years = `${snapshot.ledgerFrom!.slice(0, 4)} – ${snapshot.ledgerTo!.slice(0, 4)}`
    expect(within(view).getByText(`${years} · ${snapshot.tracks.length} tracks · ${snapshot.days.length} days`)).toBeInTheDocument()
    const terms = within(view).getAllByRole('term').map((term) => term.textContent)
    expect(terms).toEqual(['Plays counted', 'Unresolved', 'Ledger', 'Enriching'])
    const definitions = within(view).getAllByRole('definition').map((definition) => definition.textContent)
    expect(definitions[0]).toBe(String(snapshot.days.reduce((sum, day) => sum + day.plays, 0)))
    expect(definitions[1]).toBe('None')
    expect(definitions[2]).toMatch(/^[A-Z][a-z]{2} \d{4} → [A-Z][a-z]{2} \d{4}$/)
    expect(definitions[3]).toBe('your most-played first')
    expect(within(view).getByText('The DJ starts with what it knows best. More detail arrives over the next hours as tracks are enriched.')).toBeInTheDocument()
    expect(onRefresh).toHaveBeenCalledTimes(1)
    expect(api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => call.args[0])).toEqual([
      { type: 'file_inspected', surface: 'web' },
      { type: 'import_completed', surface: 'web' },
    ])

    fireEvent.click(within(view).getByRole('button', { name: 'Make your first mix' }))
    expect(onNewTape).toHaveBeenCalledTimes(1)
    fireEvent.click(within(view).getByRole('button', { name: 'Import the account data too' }))
    expect(panel()).toHaveClass('drop')
  })

  it('keeps the summary when the refresh after publishing fails', async () => {
    const { onRefresh } = await inventoryFor('extended-basic')
    onRefresh.mockRejectedValueOnce(new Error('offline'))
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))

    expect(await within(panel()).findByText('Extended history imported')).toBeInTheDocument()
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(onRefresh).toHaveBeenCalledTimes(1)
    expect(chip()).toHaveTextContent('Done')
    expect(within(panel()).queryByText('Upload interrupted')).not.toBeInTheDocument()
  })

  it('parses once across inspect and upload when the switch is untouched', async () => {
    const parser = createDirectParser()
    const parse = vi.spyOn(parser, 'parse')
    const { api } = await inventoryFor('extended-private-sessions', undefined, { parser })
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))

    await within(panel()).findByText('Extended history imported')
    expect(parse).toHaveBeenCalledTimes(1)
    expect(api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => call.args[0])).toEqual([
      { type: 'file_inspected', surface: 'web' },
      { type: 'import_completed', surface: 'web' },
    ])
  })

  it('shows the uploading state with the live chip, the stage line, the decorative band, and Cancel', async () => {
    const gate = deferred()
    const { run } = await inventoryFor('extended-basic', 'my_spotify_data_extended.zip', {
      overrides: {
        putListeningDays: async (_importId, days) => {
          await gate.held
          return { accepted: days.length }
        },
      },
    })

    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))

    await waitFor(() => expect(chip()).toHaveTextContent('Uploading 40%, tracks 1 of 1'))
    const view = panel()
    expect(within(view).getByText('my_spotify_data_extended.zip')).toBeInTheDocument()
    expect(within(view).getByText('Reading and uploading on this device')).toBeInTheDocument()
    expect(chip()).toHaveClass('wait')
    expect(within(view).getByText('Uploading tracks 1 of 1 · nothing needs to stay open in Spotify')).toBeInTheDocument()
    const band = view.querySelector('.progress') as HTMLElement
    expect(band).toHaveAttribute('aria-hidden', 'true')
    expect(band.querySelector('span')).toHaveStyle({ width: '40%' })
    expect(within(view).getByRole('button', { name: 'Cancel' })).toBeInTheDocument()
    expect(within(view).queryByRole('button', { name: 'Upload' })).not.toBeInTheDocument()
    expect(screen.queryByLabelText('choose files')).not.toBeInTheDocument()
    expect(run.getState().kind).toBe('uploading')

    gate.release()
    await within(panel()).findByText('Extended history imported')
  })

  it('cancels mid-upload: the chunk in flight was sent, nothing follows, and the inventory returns', async () => {
    const gate = deferred()
    const { api, run, parser } = await inventoryFor('extended-basic', undefined, {
      overrides: {
        putListeningTracks: async (_importId, tracks) => {
          await gate.held
          return { accepted: tracks.length }
        },
      },
    })
    const terminate = vi.spyOn(parser, 'terminate')

    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))
    await waitFor(() => expect(api.calls.some((call) => call.method === 'putListeningTracks')).toBe(true))
    fireEvent.click(within(panel()).getByRole('button', { name: 'Cancel' }))

    expect(await within(panel()).findByRole('button', { name: 'Upload' })).toBeInTheDocument()
    expect(chip()).toHaveTextContent('Readable')
    expect(run.getState().kind).toBe('inventory')
    const sentBeforeCancel = api.calls.length
    gate.release()
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(api.calls.slice(sentBeforeCancel)).toEqual([])
    expect(api.calls.some((call) => call.method === 'putListeningDays')).toBe(false)
    expect(api.calls.some((call) => call.method === 'completeListeningImport')).toBe(false)
    expect(terminate).toHaveBeenCalled()
    expect(within(panel()).getByRole('switch', { name: 'Include private sessions' })).toBeInTheDocument()
  })

  it('cancels mid-parse: the parse’s signal is aborted and the server run never begins', async () => {
    const { parser, gate, signals } = heldParser((options) => options.includePrivateSessions)
    const { api, run } = await inventoryFor('extended-private-sessions', undefined, { parser })
    fireEvent.click(within(panel()).getByRole('switch', { name: 'Include private sessions' }))
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))
    await waitFor(() => expect(signals).toHaveLength(1))
    expect(chip()).toHaveTextContent('Uploading')

    fireEvent.click(within(panel()).getByRole('button', { name: 'Cancel' }))
    expect(signals[0].aborted).toBe(true)
    expect(await within(panel()).findByRole('button', { name: 'Upload' })).toBeInTheDocument()
    expect(run.getState().kind).toBe('inventory')
    gate.release()
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(api.calls.some((call) => call.method === 'beginListeningImport')).toBe(false)
    expect(within(panel()).getByRole('switch', { name: 'Include private sessions' })).toHaveAttribute('aria-checked', 'true')
  })

  it('passes the private-sessions choice to the upload parse, not the inventory parse', async () => {
    const parser = createDirectParser()
    const parse = vi.spyOn(parser, 'parse')
    await inventoryFor('extended-private-sessions', undefined, { parser })
    expect(parse).toHaveBeenCalledTimes(1)
    expect(parse.mock.calls[0][1]).toMatchObject({ timeZone: 'UTC', includePrivateSessions: false })

    const toggle = within(panel()).getByRole('switch', { name: 'Include private sessions' })
    fireEvent.click(toggle)
    expect(toggle).toHaveAttribute('aria-checked', 'true')
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))

    await within(panel()).findByText('Extended history imported')
    expect(parse).toHaveBeenCalledTimes(2)
    expect(parse.mock.calls[1][1]).toMatchObject({ timeZone: 'UTC', includePrivateSessions: true })
  })

  it('reports an account package with the playlist count and offers the other package', async () => {
    await inventoryFor('account-basic')
    const snapshot = await facts('account-basic')
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))

    expect(await within(panel()).findByText('Account data imported')).toBeInTheDocument()
    const view = panel()
    expect(within(view).getByText(`${snapshot.library.length} liked songs · ${snapshot.artists.length} artists · ${snapshot.playlists.length} playlists`)).toBeInTheDocument()
    expect(within(view).getAllByRole('term').map((term) => term.textContent)).toEqual(['Liked songs', 'Artists', 'Playlists', 'Enriching'])
    expect(within(view).getByRole('button', { name: 'Import the extended history too' })).toBeInTheDocument()
  })

  it('shows the partial state when the playlists fail after the history landed', async () => {
    const { onRefresh, onNewTape } = await inventoryFor('account-basic', undefined, {
      overrides: {
        putPlaylists: async () => {
          throw new ApiError(409, { error: 'sync_conflict', message: 'another run is open' })
        },
      },
    })
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))

    expect(await within(panel()).findByText('Account data imported, playlists didn’t land')).toBeInTheDocument()
    const view = panel()
    expect(view).toHaveClass('attention')
    expect(within(view).getByText('Likes and followed artists are in. The playlist sync was interrupted.')).toBeInTheDocument()
    expect(chip()).toHaveTextContent('Partly done')
    expect(within(view).getByText('Your liked songs and artists are safe on the server. Nothing is lost; the playlists can follow with a retry.')).toBeInTheDocument()
    expect(within(view).getByText('Re-uploads the file; nothing is duplicated.')).toBeInTheDocument()
    expect(screen.queryByText('another run is open')).not.toBeInTheDocument()
    expect(onRefresh).toHaveBeenCalledTimes(1)
    expect(within(view).getByRole('button', { name: 'Review again' })).toHaveClass('primary')
    fireEvent.click(within(view).getByRole('button', { name: 'Make your first mix' }))
    expect(onNewTape).toHaveBeenCalledTimes(1)
  })

  it('retries the whole import from the partial state without a second file_inspected', async () => {
    let playlistAttempts = 0
    const { api, run, onRefresh } = await inventoryFor('account-basic', undefined, {
      overrides: {
        putPlaylists: async (_syncId, playlists) => {
          playlistAttempts += 1
          if (playlistAttempts === 1) throw new ApiError(500, { error: 'sync_conflict', message: 'another run is open' })
          return { accepted: playlists.length }
        },
      },
    })
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))
    await within(panel()).findByText('Account data imported, playlists didn’t land')

    fireEvent.click(within(panel()).getByRole('button', { name: 'Retry playlists' }))
    expect(run.getState().kind).toBe('uploading')
    expect(within(panel()).getByRole('button', { name: 'Cancel' })).toBeInTheDocument()

    expect(await within(panel()).findByText('Account data imported')).toBeInTheDocument()
    expect(chip()).toHaveTextContent('Done')
    expect(playlistAttempts).toBe(2)
    expect(api.calls.filter((call) => call.method === 'beginListeningImport')).toHaveLength(2)
    expect(api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => call.args[0])).toEqual([
      { type: 'file_inspected', surface: 'web' },
      { type: 'import_completed', surface: 'web' },
      { type: 'import_completed', surface: 'web' },
    ])
    expect(onRefresh).toHaveBeenCalledTimes(2)
  })

  it('keeps the inventory and says nothing was published when the upload itself fails', async () => {
    const { onRefresh } = await inventoryFor('extended-basic', undefined, {
      overrides: {
        putListeningTracks: async () => {
          throw new ApiError(500, { message: 'db exploded' })
        },
      },
    })
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))

    expect(await within(panel()).findByText('Upload interrupted')).toBeInTheDocument()
    expect(chip()).toHaveTextContent('Failed')
    expect(screen.queryByText('db exploded')).not.toBeInTheDocument()
    expect(onRefresh).not.toHaveBeenCalled()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Try again' }))
    expect(within(panel()).getByRole('button', { name: 'Upload' })).toBeInTheDocument()
  })
})

describe('ImportPanel · unreadable', () => {
  function withClipboard(writeText: ((text: string) => Promise<void>) | null) {
    const descriptor = Object.getOwnPropertyDescriptor(navigator, 'clipboard')
    Object.defineProperty(navigator, 'clipboard', {
      value: writeText ? { writeText } : undefined,
      configurable: true,
    })
    return () => {
      if (descriptor) Object.defineProperty(navigator, 'clipboard', descriptor)
      else delete (navigator as { clipboard?: unknown }).clipboard
    }
  }

  it('names the expected files, shows a content-free report, and copies exactly that report', async () => {
    const writeText = vi.fn(async () => undefined)
    const restore = withClipboard(writeText)
    try {
      renderPanel()
      pick(fixtureFile('extended-malformed', 'my_spotify_data.zip'))

      expect(await within(panel()).findByText('Couldn’t read this export')).toBeInTheDocument()
      const view = panel()
      expect(chip()).toHaveTextContent('Unreadable')
      expect(chip()).toHaveClass('err')
      expect(within(view).getByText('my_spotify_data.zip')).toBeInTheDocument()
      expect(within(view).getByText('One of the history files couldn’t be read, so nothing was uploaded. Use an Exportify ZIP or CSV, or an official Spotify ZIP. Import Exportify and official files separately. Official files: Streaming_History_Audio_*.json, YourLibrary.json, Playlist*.json.')).toBeInTheDocument()

      const report = view.querySelector('.diag') as HTMLElement
      const lines = report.textContent!.split('\n')
      expect(lines[0]).toBe('source: spotify_export')
      expect(lines[1]).toMatch(/^Spotify Extended Streaming History\/Streaming_History_Audio_2024-2025_0\.json · \d+(\.\d)? K?B · rows 2$/)
      expect(lines[2]).toMatch(/^Spotify Extended Streaming History\/Streaming_History_Audio_2025-2026_1\.json · \d+(\.\d)? K?B · unreadable$/)
      expect(lines[3]).toBe('parser web-spotify-export/1')
      expect(lines).toHaveLength(4)
      expect(within(view).getByText('The report lists file names, sizes, and row counts only. No song, artist, or personal data.')).toBeInTheDocument()

      const live = view.querySelector('[aria-live="polite"]') as HTMLElement
      expect(live).toBeInTheDocument()
      expect(live).toHaveTextContent('')
      fireEvent.click(within(view).getByRole('button', { name: 'Copy report' }))
      await waitFor(() => expect(writeText).toHaveBeenCalledWith(report.textContent))
      expect(await within(view).findByText('Report copied.')).toBeInTheDocument()
      expect(view.querySelector('[aria-live="polite"]')).toBe(live)
      expect(live).toHaveTextContent('Report copied.')

      fireEvent.click(within(view).getByRole('button', { name: 'Try another file' }))
      expect(panel()).toHaveClass('drop')
    } finally {
      restore()
    }
  })

  it('says so when the clipboard is unavailable', async () => {
    const restore = withClipboard(null)
    try {
      renderPanel()
      pick(fixtureFile('extended-malformed'))
      fireEvent.click(await within(panel()).findByRole('button', { name: 'Copy report' }))
      expect(await within(panel()).findByText('Copy isn’t available here. Select the report and copy it by hand.')).toBeInTheDocument()
    } finally {
      restore()
    }
  })

  it('never shows sentinel contents in the report for a package with identity files', async () => {
    const parser = createDirectParser()
    const parse = vi.spyOn(parser, 'parse').mockImplementation(async () => {
      const { UnreadableExportError } = await import('../import/spotify-parser')
      const expected = readExpected('account-pii-present', 'default')
      throw new UnreadableExportError('YourLibrary.json', expected.inventory)
    })
    renderPanel({ parser })
    pick(fixtureFile('account-pii-present'))

    expect(await within(panel()).findByText('Couldn’t read this export')).toBeInTheDocument()
    expect(parse).toHaveBeenCalled()
    const report = panel().querySelector('.diag') as HTMLElement
    expect(report.textContent).toContain('Spotify Account Data/Identity.json · ')
    expect(report.textContent).toContain(' · ignored')
    expect(report.textContent).not.toContain('DO-NOT-READ')
    expect(document.body.textContent).not.toContain('DO-NOT-READ')
  })

  it('handles a file that is not a ZIP at all', async () => {
    renderPanel()
    pick(new File([new Uint8Array([1, 2, 3, 4])], 'notes.txt', { type: 'text/plain' }))

    expect(await within(panel()).findByText('Couldn’t read this export')).toBeInTheDocument()
    expect(within(panel()).getByText(/couldn’t be opened as a ZIP/)).toBeInTheDocument()
    expect(within(panel()).queryByRole('button', { name: 'Copy report' })).not.toBeInTheDocument()
    expect(within(panel()).getByRole('button', { name: 'Try another file' })).toBeInTheDocument()
  })
})

describe('ImportPanel · reading', () => {
  it('offers Cancel while reading, which aborts the read', async () => {
    const { parser, gate, signals } = heldParser()
    const { run } = renderPanel({ parser })
    pick(fixtureFile('extended-basic'))
    await within(panel()).findByText('Reading on this device')
    expect(chip()).toHaveTextContent('Reading')
    await waitFor(() => expect(signals).toHaveLength(1))

    fireEvent.click(within(panel()).getByRole('button', { name: 'Cancel' }))
    expect(panel()).toHaveClass('drop')
    expect(signals[0].aborted).toBe(true)
    gate.release()
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(panel()).toHaveClass('drop')
    expect(run.getState().kind).toBe('pick')
  })
})

describe('ImportPanel · device failure', () => {
  function deadParser(overrides: Partial<PageParser> = {}): PageParser {
    const dead = async () => {
      throw new Error('worker_failed')
    }
    return { inspect: dead, parse: dead, diagnose: vi.fn(dead), terminate: vi.fn(), ...overrides }
  }

  it('says the file couldn’t be read on this device when the parser worker fails, with a way out', async () => {
    const parser = deadParser()
    renderPanel({ parser })
    pick(fixtureFile('extended-basic', 'my_spotify_data.zip'))

    expect(await within(panel()).findByText('Couldn’t read this file on this device. Try again.')).toBeInTheDocument()
    const view = panel()
    expect(view).toHaveClass('err')
    expect(within(view).getByText('my_spotify_data.zip')).toBeInTheDocument()
    expect(chip()).toHaveTextContent('Not read')
    expect(chip()).toHaveClass('err')
    expect(parser.diagnose).not.toHaveBeenCalled()
    expect(parser.terminate).toHaveBeenCalled()
    expect(within(view).queryByText(/couldn’t be opened as a ZIP/)).not.toBeInTheDocument()
    expect(within(view).queryByText(/Expected files/)).not.toBeInTheDocument()
    expect(within(view).getByRole('button', { name: 'Try again' })).toBeInTheDocument()
    fireEvent.click(within(view).getByRole('button', { name: 'Choose a different file' }))
    expect(panel()).toHaveClass('drop')
  })

  it('treats a worker that dies while building the report the same way', async () => {
    const parser = deadParser({
      parse: async () => {
        throw new Error('boom')
      },
    })
    renderPanel({ parser })
    pick(fixtureFile('extended-basic'))
    expect(await within(panel()).findByText('Couldn’t read this file on this device. Try again.')).toBeInTheDocument()
    expect(parser.diagnose).toHaveBeenCalledTimes(1)
  })

  it('reads the same file again from Try again', async () => {
    let attempts = 0
    const direct = createDirectParser()
    const parser: PageParser = {
      ...direct,
      parse: async (file, options) => {
        attempts += 1
        if (attempts === 1) throw new Error('worker_failed')
        return direct.parse(file, options)
      },
    }
    renderPanel({ parser })
    pick(fixtureFile('extended-basic'))
    fireEvent.click(await within(panel()).findByRole('button', { name: 'Try again' }))
    expect(await within(panel()).findByRole('button', { name: 'Upload' })).toBeInTheDocument()
    expect(attempts).toBe(2)
  })
})

describe('ImportPanel · run ownership', () => {
  it('keeps an upload running when the panel unmounts, and shows it again on remount', async () => {
    const gate = deferred()
    const { api, run, onRefresh, unmount } = await inventoryFor('extended-basic', undefined, {
      overrides: {
        putListeningTracks: async (_importId, tracks) => {
          await gate.held
          return { accepted: tracks.length }
        },
      },
    })
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))
    await within(panel()).findByRole('button', { name: 'Cancel' })

    unmount()
    expect(run.getState().kind).toBe('uploading')

    render(<ImportPanel run={run} onNewTape={vi.fn()} />)
    expect(within(panel()).getByRole('button', { name: 'Cancel' })).toBeInTheDocument()
    expect(chip()).toHaveTextContent('Uploading')
    expect(run.getState().kind).toBe('uploading')

    gate.release()
    expect(await within(panel()).findByText('Extended history imported')).toBeInTheDocument()
    expect(api.calls.filter((call) => call.method === 'beginListeningImport')).toHaveLength(1)
    expect(api.calls.some((call) => call.method === 'completeListeningImport')).toBe(true)
    expect(onRefresh).toHaveBeenCalledTimes(1)
  })
})

describe('ImportPanel · handle and names', () => {
  it('only scrolls through the handle while reading', async () => {
    const { parser, gate } = heldParser()
    const { handle, run } = renderPanel({ parser })
    pick(fixtureFile('extended-basic'))
    await within(panel()).findByText('Reading on this device')

    handle.current!.focus()
    expect(run.getState().kind).toBe('inspecting')
    expect(panel()).not.toHaveClass('drop')
    gate.release()
    expect(await within(panel()).findByRole('button', { name: 'Upload' })).toBeInTheDocument()
  })

  it('only scrolls through the handle while uploading', async () => {
    const gate = deferred()
    const { handle, run } = await inventoryFor('extended-basic', undefined, {
      overrides: {
        putListeningTracks: async (_importId, tracks) => {
          await gate.held
          return { accepted: tracks.length }
        },
      },
    })
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))
    await within(panel()).findByRole('button', { name: 'Cancel' })

    handle.current!.focus()
    expect(run.getState().kind).toBe('uploading')
    expect(within(panel()).getByRole('button', { name: 'Cancel' })).toBeInTheDocument()
    gate.release()
    expect(await within(panel()).findByText('Extended history imported')).toBeInTheDocument()
  })

  it('resets to the drop zone and focuses it through the handle when idle', async () => {
    const { handle } = await inventoryFor('extended-basic')
    handle.current!.focus()
    await waitFor(() => expect(panel()).toHaveClass('drop'))
    expect(panel()).toHaveFocus()
  })

  it('gives every control an accessible name in every state', async () => {
    const gate = deferred()
    const { handle } = await inventoryFor('account-basic', undefined, {
      overrides: {
        putListeningTracks: async (_importId, tracks) => {
          await gate.held
          return { accepted: tracks.length }
        },
        putPlaylists: async () => {
          throw new Error('nope')
        },
      },
    })
    const check = () => {
      for (const control of screen.getAllByRole('button')) expect(control).toHaveAccessibleName()
      for (const control of screen.queryAllByRole('switch')) expect(control).toHaveAccessibleName()
    }
    check()
    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))
    await within(panel()).findByRole('button', { name: 'Cancel' })
    check()
    gate.release()
    await within(panel()).findByText('Account data imported, playlists didn’t land')
    check()
    handle.current!.focus()
    await waitFor(() => expect(panel()).toHaveClass('drop'))
    expect(screen.getByLabelText('choose files')).toBeInTheDocument()
  })
})

it('reviews a CSV as Liked Songs and uploads no accidental playlist',async()=>{
 const {api}=renderPanel()
 pick(new File(['Track URI,Track Name,Artist Name(s)\nspotify:track:4uLU6hMCjMI75M1A2tKUQC,Quiet,Artist\n'],'liked.csv',{type:'text/csv'}))
 await screen.findByText('Review your music')
 expect(screen.getByRole('button',{name:'Upload'})).toBeDisabled()
 fireEvent.change(screen.getByLabelText('Use as'),{target:{value:'liked'}})
 fireEvent.click(screen.getByLabelText('I reviewed the collection roles and replacement targets.'))
 fireEvent.click(screen.getByRole('button',{name:'Upload'}))
 await screen.findByText('Spotify music imported')
 expect(api.calls.find(c=>c.method==='beginListeningImport')?.args[0]).toMatchObject({package:'spotify_exportify',expectedLibraryTracks:1,expectedDays:0,libraryReview:{mode:'add'}})
 expect(api.calls.find(c=>c.method==='beginPlaylistSync')?.args[0]).toMatchObject({expectedPlaylists:0,review:[]})
})

it('reads multiple CSV files together and keeps each role explicit', async () => {
  renderPanel()
  const csv = 'Track URI,Track Name,Artist Name(s)\nspotify:track:4uLU6hMCjMI75M1A2tKUQC,Song,Artist\n'
  fireEvent.change(screen.getByLabelText('choose files'), {target: { files: [new File([csv], 'first.csv'), new File([csv], 'second.csv')] }})
  await screen.findByText('Review your music')
  expect(screen.getAllByLabelText('Use as')).toHaveLength(2)
  expect(screen.getByRole('button', {name:'Upload'})).toBeDisabled()
})
it('retries a collection lookup failure without calling a readable CSV broken', async () => {
  let attempts = 0
  const {api} = renderPanel({overrides: {getSpotifyCollectionReview: async () => {
    if (++attempts === 1) throw new ApiError(503,{})
    return {library:{ids:[],fingerprint:'a'.repeat(64)},playlists:[]}
  }}})
  pick(new File(['Track URI,Track Name,Artist Name(s)\n'], 'empty.csv'))
  await screen.findByText(/Your file was read, but we couldn’t load/)
  expect(api.calls.some(c => c.method === 'beginListeningImport')).toBe(false)
  fireEvent.click(screen.getByRole('button',{name:'Try again'}))
  await screen.findByText('Review your music')
})

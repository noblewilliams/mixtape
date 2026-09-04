import { cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { ImportPanel, type ImportPanelHandle } from './ImportPanel'
import { ApiError, type MixtapeApi } from '../api/client'
import { createDirectParser } from '../import/direct-parser'
import { createListeningImportService } from '../import/import-service'
import type { PageParser } from '../import/page-parser'
import { parseExport } from '../import/spotify-parser'
import { openZipArchive } from '../import/zip-reader'
import { createFakeApi } from '../test/fake-api'
import { readExpected, readFixtureArchiveBytes } from '../test/listening-export-fixtures'

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

function renderPanel(options: { overrides?: Partial<MixtapeApi>; parser?: PageParser } = {}) {
  const api = createFakeApi(options.overrides)
  const parser = options.parser ?? createDirectParser()
  const importService = createListeningImportService({ api, parser })
  const onRefresh = vi.fn(async () => undefined)
  const onNewTape = vi.fn()
  const onBusyChange = vi.fn()
  const handle: { current: ImportPanelHandle | null } = { current: null }
  render(
    <ImportPanel
      ref={handle}
      importService={importService}
      parser={parser}
      onRefresh={onRefresh}
      onNewTape={onNewTape}
      onBusyChange={onBusyChange}
    />,
  )
  return { api, parser, onRefresh, onNewTape, onBusyChange, handle }
}

function pick(file: File) {
  fireEvent.change(screen.getByLabelText('choose a file'), { target: { files: [file] } })
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
  it('offers the drop zone with the board copy and a real file input', () => {
    renderPanel()
    const drop = panel()
    expect(drop).toHaveClass('drop')
    expect(drop).toHaveTextContent('Drop a Spotify ZIP here')
    expect(drop).toHaveTextContent('or choose a file · either package, in any order')
    const input = screen.getByLabelText('choose a file')
    expect(input).toHaveAttribute('type', 'file')
    expect(input).toHaveAttribute('accept', '.zip,application/zip')
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
    expect(within(view).getByText(/Plays hidden from followers stay out unless you choose otherwise\./)).toBeInTheDocument()
    expect(within(view).getByText('Only these plays leave this device. Your account details, payments, and IP addresses are never read.')).toBeInTheDocument()
    expect(within(view).getByRole('button', { name: 'Upload' })).toBeInTheDocument()
    expect(within(view).getByRole('button', { name: 'Choose a different file' })).toBeInTheDocument()
    expect(api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => call.args[0])).toEqual([
      { type: 'file_inspected', surface: 'web' },
    ])
    expect(api.calls.some((call) => call.method === 'beginListeningImport')).toBe(false)
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
    const { api, onRefresh, onBusyChange, onNewTape } = await inventoryFor('extended-basic')
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
    expect(onBusyChange.mock.calls.map(([busy]) => busy)).toEqual([false, true, false])
    expect(api.calls.filter((call) => call.method === 'postFunnelEvent').map((call) => call.args[0])).toEqual([
      { type: 'file_inspected', surface: 'web' },
      { type: 'import_completed', surface: 'web' },
    ])

    fireEvent.click(within(view).getByRole('button', { name: 'Make your first mix' }))
    expect(onNewTape).toHaveBeenCalledTimes(1)
    fireEvent.click(within(view).getByRole('button', { name: 'Import the account data too' }))
    expect(panel()).toHaveClass('drop')
  })

  it('shows the uploading state with the live chip, the stage line, the decorative band, and Cancel', async () => {
    const gate = deferred()
    const { onBusyChange } = await inventoryFor('extended-basic', 'my_spotify_data_extended.zip', {
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
    expect(screen.queryByLabelText('choose a file')).not.toBeInTheDocument()
    expect(onBusyChange).toHaveBeenLastCalledWith(true)

    gate.release()
    await within(panel()).findByText('Extended history imported')
  })

  it('returns to the inventory on Cancel and never completes the import', async () => {
    const gate = deferred()
    const { api, onBusyChange, parser } = await inventoryFor('extended-basic', undefined, {
      overrides: {
        putListeningTracks: async (_importId, tracks) => {
          await gate.held
          return { accepted: tracks.length }
        },
      },
    })
    const terminate = vi.spyOn(parser, 'terminate')

    fireEvent.click(within(panel()).getByRole('button', { name: 'Upload' }))
    fireEvent.click(await within(panel()).findByRole('button', { name: 'Cancel' }))

    expect(await within(panel()).findByRole('button', { name: 'Upload' })).toBeInTheDocument()
    expect(chip()).toHaveTextContent('Readable')
    gate.release()
    await new Promise((resolve) => setTimeout(resolve, 20))
    expect(api.calls.some((call) => call.method === 'completeListeningImport')).toBe(false)
    expect(api.calls.some((call) => call.method === 'putListeningDays')).toBe(false)
    expect(onBusyChange).toHaveBeenLastCalledWith(false)
    expect(terminate).toHaveBeenCalled()
    expect(within(panel()).getByRole('switch', { name: 'Include private sessions' })).toBeInTheDocument()
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
    expect(within(view).getByText(/Your liked songs and artists are safe on the server\. Nothing is lost and nothing needs re-uploading/)).toBeInTheDocument()
    expect(screen.queryByText('another run is open')).not.toBeInTheDocument()
    expect(onRefresh).toHaveBeenCalledTimes(1)
    fireEvent.click(within(view).getByRole('button', { name: 'Make a mix anyway' }))
    expect(onNewTape).toHaveBeenCalledTimes(1)
    fireEvent.click(within(view).getByRole('button', { name: 'Choose a different file' }))
    expect(panel()).toHaveClass('drop')
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
      expect(within(view).getByText('One of the history files couldn’t be read, so nothing was uploaded. Expected files: Streaming_History_Audio_*.json, YourLibrary.json, Playlist*.json.')).toBeInTheDocument()

      const report = view.querySelector('.diag') as HTMLElement
      const lines = report.textContent!.split('\n')
      expect(lines[0]).toBe('source: spotify_export')
      expect(lines[1]).toMatch(/^Spotify Extended Streaming History\/Streaming_History_Audio_2024-2025_0\.json · \d+(\.\d)? K?B · rows 2$/)
      expect(lines[2]).toMatch(/^Spotify Extended Streaming History\/Streaming_History_Audio_2025-2026_1\.json · \d+(\.\d)? K?B · unreadable$/)
      expect(lines[3]).toBe('parser web-spotify-export/1')
      expect(lines).toHaveLength(4)
      expect(within(view).getByText('The report lists file names, sizes, and row counts only. No song, artist, or personal data.')).toBeInTheDocument()

      fireEvent.click(within(view).getByRole('button', { name: 'Copy report' }))
      await waitFor(() => expect(writeText).toHaveBeenCalledWith(report.textContent))
      expect(await within(view).findByText('Report copied.')).toBeInTheDocument()

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

describe('ImportPanel · handle and names', () => {
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
    expect(screen.getByLabelText('choose a file')).toBeInTheDocument()
  })
})

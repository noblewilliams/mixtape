import { describe, expect, it, vi } from 'vitest'
import { createDirectParser } from './direct-parser'
import { createLazyParser, type PageParser } from './page-parser'
import { UnreadableExportError } from './spotify-parser'
import { readExpected, readFixtureArchive } from '../test/listening-export-fixtures'

function fakeParser(): PageParser & { terminated: number } {
  const parser = {
    terminated: 0,
    inspect: vi.fn(async () => ({ package: null, read: [], ignored: [] })),
    parse: vi.fn(async () => {
      throw new Error('not used')
    }),
    diagnose: vi.fn(async () => ({ source: 'spotify_export' as const, parserVersion: 'x', files: [] })),
    terminate: vi.fn(() => {
      parser.terminated += 1
    }),
  }
  return parser
}

describe('createLazyParser', () => {
  it('creates nothing until the first call, then reuses that parser', async () => {
    const created: ReturnType<typeof fakeParser>[] = []
    const lazy = createLazyParser(() => {
      const parser = fakeParser()
      created.push(parser)
      return parser
    })
    expect(created).toHaveLength(0)

    await lazy.inspect(new Blob([]))
    await lazy.diagnose(new Blob([]))
    expect(created).toHaveLength(1)
    expect(created[0].inspect).toHaveBeenCalledTimes(1)
    expect(created[0].diagnose).toHaveBeenCalledTimes(1)
  })

  it('terminates the live parser and starts a fresh one on the next call', async () => {
    const created: ReturnType<typeof fakeParser>[] = []
    const lazy = createLazyParser(() => {
      const parser = fakeParser()
      created.push(parser)
      return parser
    })
    lazy.terminate()
    expect(created).toHaveLength(0)

    await lazy.inspect(new Blob([]))
    lazy.terminate()
    expect(created[0].terminated).toBe(1)
    await lazy.inspect(new Blob([]))
    expect(created).toHaveLength(2)
    expect(created[0].inspect).toHaveBeenCalledTimes(1)
    expect(created[1].inspect).toHaveBeenCalledTimes(1)
  })
})

describe('createDirectParser', () => {
  it('parses a fixture in-page with the same inventory as the expected file', async () => {
    const parser = createDirectParser()
    const inventory = await parser.inspect(readFixtureArchive('account-basic'))
    expect(inventory).toEqual(readExpected('account-basic', 'default').inventory)
    const { snapshot } = await parser.parse(readFixtureArchive('account-basic'), {
      timeZone: 'Africa/Lagos',
      includePrivateSessions: false,
    })
    expect(snapshot.package).toBe('spotify_account')
    const diagnostics = await parser.diagnose(readFixtureArchive('account-basic'))
    expect(diagnostics.files.map((file) => file.path)).toContain('Spotify Account Data/YourLibrary.json')
    parser.terminate()
  })

  it('fails closed on a broken archive like the worker does', async () => {
    const parser = createDirectParser()
    await expect(
      parser.parse(readFixtureArchive('extended-malformed'), { timeZone: 'UTC', includePrivateSessions: false }),
    ).rejects.toBeInstanceOf(UnreadableExportError)
  })
})

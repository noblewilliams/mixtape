import { describe, expect, it } from 'vitest'
import { openZipArchive } from './zip-reader'
import { readExpected, readFixtureArchive } from '../test/listening-export-fixtures'
import { buildZipBlob } from '../test/zip-builder'

describe('openZipArchive', () => {
  it('lists every file entry with its path and uncompressed byte size from the central directory', async () => {
    const archive = await openZipArchive(readFixtureArchive('account-pii-present'))
    const entries = await archive.entries()
    const { inventory } = readExpected('account-pii-present', 'default')
    expect(entries).toEqual(expect.arrayContaining(inventory.ignored))
    expect(entries.map((entry) => entry.path).sort()).toEqual(
      [...inventory.read.map((file) => file.path), ...inventory.ignored.map((file) => file.path)].sort(),
    )
    expect(inventory.ignored.length).toBeGreaterThanOrEqual(5)
    expect(entries.find((entry) => entry.path === 'Spotify Account Data/Identity.json')?.bytes).toBe(2068)
  })

  it('decompresses one requested entry as UTF-8 text', async () => {
    const archive = await openZipArchive(readFixtureArchive('account-pii-present'))
    const text = await archive.readText('Spotify Account Data/YourLibrary.json')
    const parsed = JSON.parse(text) as { tracks: unknown[]; artists: unknown[] }
    expect(parsed.tracks).toHaveLength(1)
    expect(parsed.artists).toHaveLength(1)
  })

  it('rejects a path that is not in the archive', async () => {
    const archive = await openZipArchive(readFixtureArchive('account-pii-present'))
    await expect(archive.readText('Spotify Account Data/Missing.json')).rejects.toThrow(/not in the archive/)
  })

  it('skips directory entries and keeps nested paths verbatim', async () => {
    const zip = await buildZipBlob([
      { path: 'my_spotify_data/', directory: true },
      { path: 'my_spotify_data/Spotify Account Data/', directory: true },
      { path: 'my_spotify_data/Spotify Account Data/YourLibrary.json', text: '{"tracks":[],"artists":[]}' },
      { path: 'my_spotify_data/Spotify Account Data/Playlist1.json', text: '{"playlists":[]}' },
    ])
    const archive = await openZipArchive(zip)
    const entries = await archive.entries()
    expect(entries.map((entry) => entry.path).sort()).toEqual([
      'my_spotify_data/Spotify Account Data/Playlist1.json',
      'my_spotify_data/Spotify Account Data/YourLibrary.json',
    ])
    expect(entries.find((entry) => entry.path.endsWith('YourLibrary.json'))?.bytes).toBe(26)
    expect(await archive.readText('my_spotify_data/Spotify Account Data/Playlist1.json')).toBe('{"playlists":[]}')
  })

  it('reads entries written with a data descriptor, sizing them from the central directory', async () => {
    const text = '{"playlists":[{"name":"Descriptor","items":[]}]}'
    const zip = await buildZipBlob([{ path: 'Spotify Account Data/Playlist1.json', text, dataDescriptor: true }])
    const archive = await openZipArchive(zip)
    expect(await archive.entries()).toEqual([{ path: 'Spotify Account Data/Playlist1.json', bytes: text.length }])
    expect(await archive.readText('Spotify Account Data/Playlist1.json')).toBe(text)
  })

  it('drops a UTF-8 byte order mark and rejects malformed UTF-8', async () => {
    const bom = new Uint8Array([0xef, 0xbb, 0xbf, ...new TextEncoder().encode('{"tracks":[]}')])
    const broken = new Uint8Array([0x7b, 0x22, 0xff, 0xfe, 0x22, 0x7d])
    const zip = await buildZipBlob([
      { path: 'Spotify Account Data/YourLibrary.json', bytes: bom },
      { path: 'Spotify Account Data/Playlist1.json', bytes: broken },
    ])
    const archive = await openZipArchive(zip)
    expect(await archive.readText('Spotify Account Data/YourLibrary.json')).toBe('{"tracks":[]}')
    await expect(archive.readText('Spotify Account Data/Playlist1.json')).rejects.toThrow(TypeError)
  })

  it('rejects a read whose signal is already aborted', async () => {
    const archive = await openZipArchive(readFixtureArchive('account-pii-present'))
    const controller = new AbortController()
    controller.abort()
    await expect(
      archive.readText('Spotify Account Data/YourLibrary.json', { signal: controller.signal }),
    ).rejects.toMatchObject({ name: 'AbortError' })
  })

  it('rejects a blob that is not a ZIP archive', async () => {
    await expect(openZipArchive(new Blob(['not a zip file at all'], { type: 'text/plain' }))).rejects.toThrow()
  })
})

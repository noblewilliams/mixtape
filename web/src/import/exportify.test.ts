import { expect, it } from 'vitest'
import { exportifyHeaders } from './exportify-headers'
import { resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { parseExport } from './spotify-parser'
import type { ExportArchive } from './zip-reader'
const id = '4uLU6hMCjMI75M1A2tKUQC'
const options = { timeZone: 'Africa/Lagos', includePrivateSessions: false }
const archive = (files: Record<string, string>): ExportArchive => ({
  entries: async () =>
    Object.entries(files).map(([path, text]) => ({
      path,
      bytes: new TextEncoder().encode(text).length,
    })),
  readText: async (path) => files[path],
})
it('reads Exportify quoted rows, preserving repeated and unresolved occurrences without silently liking them', async () => {
  const text =
    '\ufeff"Track URI","Track Name","Artist Name(s)","Album Name","Track Duration (ms)"\r\n' +
    `"spotify:track:${id}","A ""quiet""\nnight","One, Two","Moon","200000"\r\n` +
    `"spotify:track:${id}","Again","One","Moon","200000"\r\n` +
    '"spotify:local:test","Local","Home","",""\r\n'
  const result = await parseExport(archive({ 'liked.csv': text }), options)
  expect(result.snapshot.package).toBe('spotify_exportify')
  expect(result.snapshot.tracks).toHaveLength(1)
  expect(result.snapshot.tracks[0].title).toBe('A "quiet"\nnight')
  expect(result.snapshot.playlists[0].entries.map((e) => e.platformId)).toEqual(
    [id, id, null],
  )
  expect(result.snapshot.library).toEqual([])
  expect(result.snapshot.days).toEqual([])
  expect(result.inventory.read).toEqual([{ path: 'liked.csv', rows: 3 }])
})

it('accepts translated headers and an empty collection while rejecting broken and mixed exports', async () => {
  const french = '"URI du titre","Nom du titre","Nom(s) de l\'artiste"\n'
  expect(
    (await parseExport(archive({ 'quiet.csv': french }), options)).snapshot
      .playlists[0].entries,
  ).toEqual([])
  await expect(
    parseExport(
      archive({
        'quiet.csv': 'Track URI,Track Name,Artist Name(s)\n"unfinished',
      }),
      options,
    ),
  ).rejects.toMatchObject({ name: 'UnreadableExportError' })
  await expect(
    parseExport(
      archive({ 'quiet.csv': french, 'YourLibrary.json': '{}' }),
      options,
    ),
  ).rejects.toMatchObject({ name: 'UnreadableExportError' })
  await expect(
    parseExport(
      archive({
        'quiet.csv': 'Track URI,Track URI,Track Name,Artist Name(s)\n',
      }),
      options,
    ),
  ).rejects.toMatchObject({ name: 'UnreadableExportError' })
})
it('honours cancellation and rejects declared oversize archives before reading file contents', async () => {
  const controller = new AbortController()
  controller.abort()
  await expect(
    parseExport(archive({ 'x.csv': 'Track URI,Track Name,Artist Name(s)' }), {
      ...options,
      signal: controller.signal,
    }),
  ).rejects.toMatchObject({ name: 'AbortError' })
  let reads = 0
  await expect(
    parseExport(
      {
        entries: async () => [{ path: 'x.csv', bytes: 70 * 1024 * 1024 }],
        readText: async () => {
          reads++
          return ''
        },
      },
      options,
    ),
  ).rejects.toMatchObject({ name: 'UnreadableExportError' })
  expect(reads).toBe(0)
})

it('matches the shared web/native snapshot contract', async () => {
  const { readFileSync } = await import('node:fs')
  const text = readFileSync(
    resolve(
      fileURLToPath(import.meta.url),
      '../../../../fixtures/exportify/sample.csv',
    ),
    'utf8',
  )
  const expected = JSON.parse(
    readFileSync(
      resolve(
        fileURLToPath(import.meta.url),
        '../../../../fixtures/exportify/expected.json',
      ),
      'utf8',
    ),
  )
  expect(
    (
      await parseExport(archive({ 'sample.csv': text }), {
        ...options,
        timeZone: 'UTC',
      })
    ).snapshot,
  ).toEqual(expected)
})

it('keeps translated header support aligned with the shared fixture', async () => {
  const { readFileSync } = await import('node:fs')
  expect(exportifyHeaders).toEqual(
    JSON.parse(
      readFileSync(
        resolve(
          fileURLToPath(import.meta.url),
          '../../../../fixtures/exportify/headers.json',
        ),
        'utf8',
      ),
    ),
  )
})

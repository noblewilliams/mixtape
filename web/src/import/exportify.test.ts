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

const second = '7ouMYWpwJ422jRcDASZB7P'
const isrcTracks = async (files: Record<string, string>) =>
  (await parseExport(archive(files), options)).snapshot

it('carries a well-formed ISRC on the track, normalised, and omits it otherwise', async () => {
  const head = '"Track URI","Track Name","Artist Name(s)","ISRC"\n'
  const snapshot = await isrcTracks({
    'a.csv':
      head +
      `"spotify:track:${id}","One","A"," us-rc1-76-07839 "\n` +
      `"spotify:track:${second}","Two","B","not an isrc"\n`,
  })
  expect(snapshot.tracks).toEqual([
    {
      platformId: id,
      title: 'One',
      artist: 'A',
      album: null,
      durationMs: null,
      isrc: 'USRC17607839',
    },
    {
      platformId: second,
      title: 'Two',
      artist: 'B',
      album: null,
      durationMs: null,
    },
  ])
  expect('isrc' in snapshot.tracks[1]).toBe(false)
  expect(
    snapshot.playlists[0].entries.every((entry) => !('isrc' in entry)),
  ).toBe(true)
})

it('keeps the first well-formed ISRC for a recording across rows and files', async () => {
  const head = '"Track URI","Track Name","Artist Name(s)","ISRC"\n'
  const snapshot = await isrcTracks({
    'a.csv': head + `"spotify:track:${id}","One","A",""\n`,
    'b.csv':
      head +
      `"spotify:track:${id}","One","A","bad"\n` +
      `"spotify:track:${id}","One","A","GBAYE0000001"\n` +
      `"spotify:track:${id}","One","A","USRC17607839"\n`,
    'c.csv': head + `"spotify:track:${id}","One","A","FRZ039800212"\n`,
  })
  expect(snapshot.tracks.map((t) => t.isrc)).toEqual(['GBAYE0000001'])
  expect(snapshot.tracks[0].title).toBe('One')
})

it('reads the ISRC column beside translated headers and in any letter case', async () => {
  const snapshot = await isrcTracks({
    'quiet.csv':
      '"URI du titre","Nom du titre","Nom(s) de l\'artiste","isrc"\n' +
      `"spotify:track:${id}","Un","A","FRZ039800212"\n`,
  })
  expect(snapshot.tracks[0].isrc).toBe('FRZ039800212')
})

it('never lets a missing or ambiguous ISRC column change the rest of the import', async () => {
  const plain = await isrcTracks({
    'a.csv':
      '"Track URI","Track Name","Artist Name(s)"\n' +
      `"spotify:track:${id}","One","A"\n`,
  })
  const doubled = await isrcTracks({
    'a.csv':
      '"Track URI","Track Name","Artist Name(s)","ISRC","ISRC"\n' +
      `"spotify:track:${id}","One","A","USRC17607839","GBAYE0000001"\n`,
  })
  expect('isrc' in plain.tracks[0]).toBe(false)
  expect('isrc' in doubled.tracks[0]).toBe(false)
  expect(doubled.tracks).toEqual(plain.tracks)
  expect(doubled.playlists[0].entries).toEqual(plain.playlists[0].entries)
})

it('rejects ISRC shapes outside the contract', async () => {
  const head = '"Track URI","Track Name","Artist Name(s)","ISRC"\n'
  for (const cell of [
    'USRC1760783',
    'USRC176078390',
    '1SRC17607839',
    'USRC1760783X',
    'US_RC17607839',
    'ÜSRC17607839',
  ]) {
    const snapshot = await isrcTracks({
      'a.csv': head + `"spotify:track:${id}","One","A","${cell}"\n`,
    })
    expect('isrc' in snapshot.tracks[0]).toBe(false)
  }
})

// Export All has written saved_albums.csv beside the playlists since upstream
// #240 (October 2026): one row per album, no track columns.
const trackHeader =
  '"Track URI","Track Name","Artist URI(s)","Artist Name(s)","Album URI","Album Name",' +
  '"Album Artist URI(s)","Album Artist Name(s)","Album Release Date","Album Image URL",' +
  '"Disc Number","Track Number","Track Duration (ms)","Track Preview URL","Explicit",' +
  '"Popularity","ISRC","Added By","Added At"\n'
const trackRow = (name: string) =>
  `"spotify:track:${id}","${name}","spotify:artist:0000000000000000000001","Ana",` +
  '"spotify:album:0000000000000000000002","An Album","spotify:artist:0000000000000000000001",' +
  '"Ana","2020-01-01","https://i.scdn.co/image/x","1","1","200000","","false","50",' +
  '"USRC17607839","","2024-05-01T10:00:00Z"\n'
const savedAlbums =
  '"Album URI","Album Name","Album Artist URI(s)","Album Artist Name(s)","Album Type",' +
  '"Album Release Date","Total Tracks","Label","UPC","Popularity","Album Image URL","Added At"\n' +
  '"spotify:album:1ATL5GLyefJaxhQzSPVrLX","Arrival","spotify:artist:0LcJLqbBmaGUft1e9Mm8HV",' +
  '"ABBA","album","1976-10-11","10","Polar Music","731454993620","70",' +
  '"https://i.scdn.co/image/a","2025-01-02T03:04:05Z"\n'

it('an Export All archive with saved albums imports every playlist and sets the album list aside', async () => {
  const files = {
    '#23.csv': trackHeader + trackRow('One'),
    "abba's_vibe.csv": trackHeader + trackRow('One') + trackRow('Again'),
    'audio_hugs_🫂📝🥺💌.csv': trackHeader + trackRow('One'),
    'cover.jpg': 'jpeg',
    'liked.csv': trackHeader + trackRow('One'),
    'saved_albums.csv': savedAlbums,
    'zz_last.csv': trackHeader + trackRow('One'),
  }
  const result = await parseExport(archive(files), options)
  expect(result.snapshot.playlists.map((p) => p.name)).toEqual([
    '#23',
    "abba's vibe",
    'audio hugs 🫂📝🥺💌',
    'liked',
    'zz last',
  ])
  // The review pairs read files with playlists by index, so an album list
  // is never among the read files.
  expect(result.inventory.read.map((f) => f.path)).toEqual([
    '#23.csv',
    "abba's_vibe.csv",
    'audio_hugs_🫂📝🥺💌.csv',
    'liked.csv',
    'zz_last.csv',
  ])
  expect(result.inventory.ignored).toEqual([
    { path: 'cover.jpg', bytes: 4 },
    {
      path: 'saved_albums.csv',
      bytes: new TextEncoder().encode(savedAlbums).length,
    },
  ])
})

it('tells an album list apart by its album URIs, and still rejects any other CSV', async () => {
  const good = `"Track URI","Track Name","Artist Name(s)"\n"spotify:track:${id}","One","A"\n`
  const french =
    '"URI de l\'album","Nom de l\'album"\n"spotify:album:1ATL5GLyefJaxhQzSPVrLX","Arrival"\n'
  const result = await parseExport(
    archive({ 'a.csv': good, 'mes_albums.csv': french }),
    options,
  )
  expect(result.snapshot.playlists.map((p) => p.name)).toEqual(['a'])
  expect(result.inventory.ignored.map((f) => f.path)).toEqual(['mes_albums.csv'])
  for (const other of [
    '"Name","Value"\n"x","y"\n',
    '"Album URI","Album Name"\n"spotify:album:1ATL5GLyefJaxhQzSPVrLX","Arrival"\n' +
      `"spotify:track:${id}","Not an album"\n`,
    '"Album URI","Album Name"\n',
  ]) {
    await expect(
      parseExport(archive({ 'a.csv': good, 'odd.csv': other }), options),
    ).rejects.toMatchObject({ name: 'UnreadableExportError', file: 'odd.csv' })
  }
})

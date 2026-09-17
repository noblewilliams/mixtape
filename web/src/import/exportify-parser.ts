import { canonicalize } from './canonical'
import { exportifyHeaders } from './exportify-headers'
import type {
  ExportInventory,
  SnapshotTrack,
  SnapshotPlaylist,
} from './snapshot'
import { UnreadableExportError } from './unreadable-error'
import type { ExportArchive } from './zip-reader'
import type { ParseOptions, ParseResult } from './spotify-parser'

export const isCsvPath = (path: string) =>
  /\.csv$/i.test(path) &&
  !path.split('/').some((p) => p === '__MACOSX' || p.startsWith('._'))
const MAX_BYTES = 64 * 1024 * 1024
const MAX_ROWS = 100_000
const MAX_FIELD = 10_000

/** Strict CSV, including embedded newlines and doubled quotes; yields for cancellation. */
async function csv(text: string, signal?: AbortSignal): Promise<string[][]> {
  const rows: string[][] = []
  let row: string[] = [],
    field = '',
    quoted = false,
    closed = false
  const cell = () => {
    row.push(field)
    field = ''
    closed = false
    if (row.length > 100) throw new Error('columns')
  }
  const end = () => {
    cell()
    if (row.some((v) => v !== '')) rows.push(row)
    row = []
    if (rows.length > MAX_ROWS + 1) throw new Error('rows')
  }
  text = text.replace(/^\uFEFF/, '')
  for (let i = 0; i < text.length; i++) {
    if (i % 65536 === 0) {
      await new Promise<void>((resolve) => setTimeout(resolve, 0))
      signal?.throwIfAborted()
    }
    const c = text[i]
    if (quoted) {
      if (c === '"') {
        if (text[i + 1] === '"') {
          field += '"'
          i++
        } else {
          quoted = false
          closed = true
        }
      } else field += c
    } else if (c === ',') cell()
    else if (c === '\r' || c === '\n') {
      end()
      if (c === '\r' && text[i + 1] === '\n') i++
    } else if (c === '"' && field === '' && !closed) quoted = true
    else if (closed || c === '"') throw new Error('quoting')
    else field += c
    if (field.length > MAX_FIELD) throw new Error('field')
  }
  if (quoted) throw new Error('quoting')
  if (field || row.length || closed) end()
  return rows
}
const normalize = (s: string) => s.trim().normalize('NFC').toLowerCase()

export async function parseExportify(
  archive: ExportArchive,
  options: ParseOptions,
): Promise<ParseResult> {
  const files = [...(await archive.entries())].sort((a, b) =>
    a.path < b.path ? -1 : a.path > b.path ? 1 : 0,
  )
  const selected = files.filter((f) => isCsvPath(f.path))
  const inventory: ExportInventory = {
    package: 'spotify_exportify',
    read: [],
    ignored: files.filter((f) => !isCsvPath(f.path)),
  }
  const fail = (path: string | null): never => {
    throw new UnreadableExportError(path, inventory)
  }
  if (
    selected.length > 2000 ||
    new Set(files.map((f) => f.path)).size !== files.length ||
    selected.reduce((n, f) => n + f.bytes, 0) > MAX_BYTES
  )
    fail(null)
  const tracks = new Map<string, SnapshotTrack>(),
    playlists: SnapshotPlaylist[] = []
  let unresolved = 0,
    totalRows = 0
  options.signal?.throwIfAborted()
  options.onProgress?.({
    stage: 'listing',
    file: null,
    completed: 0,
    total: selected.length,
  })
  for (const file of selected) {
    options.onProgress?.({
      stage: 'reading',
      file: file.path,
      completed: playlists.length,
      total: selected.length,
    })
    try {
      const text = await archive.readText(file.path, { signal: options.signal })
      if (text.length > MAX_BYTES) fail(file.path)
      const [header, ...rows] = await csv(text, options.signal)
      if (!header) fail(file.path)
      const columns = new Map<string, number>()
      header.forEach((h, i) => {
        for (const [key, labels] of Object.entries(exportifyHeaders)) {
          if (labels.some((label) => normalize(label) === normalize(h))) {
            if (columns.has(key)) fail(file.path)
            columns.set(key, i)
          }
        }
      })
      if (
        ['track_uri', 'track_name', 'artist_names'].some((k) => !columns.has(k))
      )
        fail(file.path)
      totalRows += rows.length
      if (totalRows > MAX_ROWS) fail(file.path)
      const value = (r: string[], k: string) =>
        columns.has(k) ? r[columns.get(k)!] : ''
      const entries = rows.map((r, position) => {
        if (r.length !== header.length) fail(file.path)
        const platformId =
          /^spotify:track:([A-Za-z0-9]{22})$/.exec(
            value(r, 'track_uri'),
          )?.[1] ?? null
        const title = value(r, 'track_name').trim() || 'Untitled'
        const artist =
          value(r, 'artist_names').trim().replace(/\\,/g, ',') ||
          'Unknown Artist'
        const album = value(r, 'album_name').trim() || null
        const duration = value(r, 'track_duration')
        const durationMs =
          /^\d+$/.test(duration) && Number(duration) <= 86_400_000
            ? Number(duration)
            : null
        if (platformId && !tracks.has(platformId))
          tracks.set(platformId, {
            platformId,
            title,
            artist,
            album,
            durationMs,
          })
        if (!platformId) unresolved++
        const timestamp = value(r, 'added_at')
        const parsed = /^\d{4}-\d{2}-\d{2}T.*(?:Z|[+-]\d{2}:\d{2})$/.test(
          timestamp,
        )
          ? Date.parse(timestamp)
          : NaN
        return {
          position,
          platformId,
          title,
          artist,
          album,
          addedAt: Number.isFinite(parsed) ? parsed : null,
        }
      })
      const digest = await crypto.subtle.digest(
        'SHA-256',
        new TextEncoder().encode(text),
      )
      const key = [...new Uint8Array(digest)]
        .map((b) => b.toString(16).padStart(2, '0'))
        .join('')
      playlists.push({
        ordinal: playlists.length,
        key,
        name: file.path
          .split('/')
          .at(-1)!
          .replace(/\.csv$/i, '')
          .replace(/_/g, ' '),
        description: null,
        lastModifiedAt: null,
        entries,
      })
      inventory.read.push({ path: file.path, rows: rows.length })
    } catch {
      options.signal?.throwIfAborted()
      if (!inventory.read.some((f) => f.path === file.path))
        inventory.read.push({ path: file.path, rows: null })
      fail(file.path)
    }
  }
  options.signal?.throwIfAborted()
  options.onProgress?.({
    stage: 'complete',
    file: null,
    completed: selected.length,
    total: selected.length,
  })
  return {
    inventory,
    snapshot: canonicalize({
      source: 'spotify_export',
      package: 'spotify_exportify',
      timeZone: options.timeZone,
      country: null,
      tracks: [...tracks.values()],
      days: [],
      library: [],
      artists: [],
      playlists,
      unresolved: { rows: unresolved, plays: 0 },
      ledgerFrom: null,
      ledgerTo: null,
    }),
    stats: {
      podcastOrAudiobook: 0,
      localFile: unresolved,
      privateSession: 0,
      badTimestamp: 0,
      privatePlays: 0,
    },
  }
}

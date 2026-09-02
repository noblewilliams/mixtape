// The report a listener can choose to send when an archive fails closed:
// file names, byte sizes, row counts, and top-level key names. Never a value.

import { PARSER_VERSION, loadRecords, planArchive } from './spotify-parser'
import type { ExportArchive } from './zip-reader'

export type DiagnosticsFile = {
  path: string
  bytes: number
  /** Row count for a file the package reads and decodes; null otherwise. */
  rows: number | null
  /** Top-level keys of the first array element (history) or of the object (library, playlist); null when not read or broken. */
  headers: string[] | null
}

export type ExportDiagnostics = {
  source: 'spotify_export'
  parserVersion: string
  files: DiagnosticsFile[]
}

export type DiagnoseOptions = {
  signal?: AbortSignal
}

export async function diagnoseExport(archive: ExportArchive, options: DiagnoseOptions = {}): Promise<ExportDiagnostics> {
  const plan = await planArchive(archive)
  const files: DiagnosticsFile[] = []
  for (const file of plan.files) {
    if (!file.read || file.kind === null) {
      files.push({ path: file.path, bytes: file.bytes, rows: null, headers: null })
      continue
    }
    options.signal?.throwIfAborted()
    let rows: number | null = null
    let headers: string[] | null = null
    try {
      const loaded = loadRecords(file.kind, await archive.readText(file.path, { signal: options.signal }))
      rows = loaded.rows
      headers = loaded.headers
    } catch (error) {
      options.signal?.throwIfAborted()
      void error
    }
    files.push({ path: file.path, bytes: file.bytes, rows, headers })
  }
  return { source: 'spotify_export', parserVersion: PARSER_VERSION, files }
}

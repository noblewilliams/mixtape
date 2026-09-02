import { readdirSync, readFileSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import type { ExportInventory } from '../import/snapshot'
import type { ExportArchive } from '../import/zip-reader'

// fileURLToPath takes the string: under jsdom the global URL class is jsdom's,
// which Node's fileURLToPath refuses.
export const FIXTURES_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '../../../fixtures/listening-exports')

export type FixtureOption = {
  name: string
  timeZone: string
  includePrivateSessions: boolean
}

export type FixtureCase = {
  name: string
  package: 'spotify_extended' | 'spotify_account' | null
  options: FixtureOption[]
  /** Paths of entries the parser must never open. */
  sentinelPaths: string[]
}

type CaseDefinition = {
  package: FixtureCase['package']
  entries: { path: string; sentinel?: boolean }[]
  options: FixtureOption[]
}

export type ExpectedFile = {
  inventory: ExportInventory
  snapshot?: unknown
  error?: { code: 'unreadable'; file: string | null }
}

export function listFixtureCases(): FixtureCase[] {
  const src = join(FIXTURES_ROOT, 'src')
  return readdirSync(src, { withFileTypes: true })
    .filter((dirent) => dirent.isDirectory())
    .map((dirent) => dirent.name)
    .sort((a, b) => (a < b ? -1 : a > b ? 1 : 0))
    .filter((name) => existsSync(join(FIXTURES_ROOT, name, 'archive.zip')))
    .map((name) => {
      const definition = JSON.parse(readFileSync(join(src, name, 'case.json'), 'utf8')) as CaseDefinition
      return {
        name,
        package: definition.package,
        options: definition.options,
        sentinelPaths: definition.entries.filter((entry) => entry.sentinel === true).map((entry) => entry.path),
      }
    })
}

export function readFixtureArchiveBytes(caseName: string): Uint8Array<ArrayBuffer> {
  const buffer = readFileSync(join(FIXTURES_ROOT, caseName, 'archive.zip'))
  const bytes = new Uint8Array(new ArrayBuffer(buffer.byteLength))
  bytes.set(buffer)
  return bytes
}

export function readFixtureArchive(caseName: string): Blob {
  return new Blob([readFixtureArchiveBytes(caseName)], { type: 'application/zip' })
}

export function readExpected(caseName: string, optionName: string): ExpectedFile {
  return JSON.parse(readFileSync(join(FIXTURES_ROOT, caseName, `expected.${optionName}.json`), 'utf8')) as ExpectedFile
}

/** Wraps an archive so every `readText` call is recorded. */
export function recordingArchive(archive: ExportArchive): ExportArchive & { readPaths: string[] } {
  const readPaths: string[] = []
  return {
    readPaths,
    entries: () => archive.entries(),
    readText(path, options) {
      readPaths.push(path)
      return archive.readText(path, options)
    },
  }
}

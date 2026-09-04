// What the import page needs from a parser: the service's inspect and parse,
// plus diagnose for the unreadable state and terminate to let the Worker go.
// The production parser is lazy, so no Worker exists until the first file is
// inspected, and each terminate (cancel, finish) frees it; the next call
// spawns a fresh one.

import type { ExportDiagnostics } from './diagnostics'
import type { ImportParser } from './import-service'
import { createParserWorkerClient, spawnParserWorker } from './worker-client'

export type PageParser = ImportParser & {
  diagnose(file: Blob, options?: { signal?: AbortSignal }): Promise<ExportDiagnostics>
  /** Rejects pending calls and releases whatever backs the parser; a later call starts fresh. */
  terminate(): void
}

export function createLazyParser(create: () => PageParser): PageParser {
  let live: PageParser | null = null
  const current = () => (live ??= create())
  return {
    inspect: (file, options) => current().inspect(file, options),
    parse: (file, options) => current().parse(file, options),
    diagnose: (file, options) => current().diagnose(file, options),
    terminate() {
      const parser = live
      live = null
      parser?.terminate()
    },
  }
}

/** The in-page parser, loaded on demand so the main bundle never carries it where Workers exist. */
function createFallbackParser(): PageParser {
  const loaded = import('./direct-parser').then((module) => module.createDirectParser())
  return {
    inspect: async (file, options) => (await loaded).inspect(file, options),
    parse: async (file, options) => (await loaded).parse(file, options),
    diagnose: async (file, options) => (await loaded).diagnose(file, options),
    terminate() {
      void loaded.then((parser) => parser.terminate())
    },
  }
}

/** A Worker-backed parser where the platform has Workers, the in-page parser otherwise. */
export function createPageParser(): PageParser {
  if (typeof Worker === 'undefined') return createFallbackParser()
  return createParserWorkerClient(spawnParserWorker())
}

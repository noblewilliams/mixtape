// The parser run on the calling thread: the tests' parser, and the page's
// fallback where Workers are unavailable. Same calls as the Worker client.

import { diagnoseExport } from './diagnostics'
import type { PageParser } from './page-parser'
import { inspectExport, parseExport } from './spotify-parser'
import { openExportArchive } from './zip-reader'

export function createDirectParser(): PageParser {
  return {
    inspect: async (file, options = {}) => inspectExport(await openExportArchive(file), { signal: options.signal }),
    parse: async (file, options) => parseExport(await openExportArchive(file), options),
    diagnose: async (file, options = {}) => diagnoseExport(await openExportArchive(file), { signal: options.signal }),
    terminate() {
      // Nothing is held between calls.
    },
  }
}

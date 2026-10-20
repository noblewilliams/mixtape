import type { MixtapeApi } from '../../api/client'
import { createImportRun, type ImportRun } from '../../import/import-run'
import { createListeningImportService } from '../../import/import-service'
import { createLazyParser, createPageParser, type PageParser } from '../../import/page-parser'
import type { MusicKitClient } from '../../musickit/client'
import { createMusicSyncRun, type MusicSyncRun } from '../../sync/music-sync-run'
import { createMusicSyncService } from '../../sync/music-sync-service'
import { createUploadGate } from '../../sync/upload-gate'

export type FirstRunApi = Pick<MixtapeApi, 'createSession' | 'putArtistSeeds' | 'postFunnelEvent'>

/**
 * What the first-run pages need from outside: the API for seeds, the first
 * mix and the request mark, the same sync and import runs the Library uses,
 * and ensureSession(), which creates the anonymous session right before the
 * first server action (a no-op once a session exists).
 */
export type FirstRunServices = {
  api: FirstRunApi
  syncRun: MusicSyncRun
  importRun: ImportRun
  ensureSession: () => Promise<void>
}

type CreateDeps = {
  api: MixtapeApi
  musicKit: MusicKitClient
  ensureSession: () => Promise<void>
  parser?: PageParser
}

/**
 * The runs for a browser with no session yet. Built the way the signed-in
 * workspace builds its own, from the same factories; nothing here touches
 * the network until a page starts a sync or an upload.
 */
export function createFirstRunServices({ api, musicKit, ensureSession, parser }: CreateDeps): FirstRunServices {
  const uploadGate = createUploadGate()
  const pageParser = parser ?? createLazyParser(createPageParser)
  const importService = createListeningImportService({ api, parser: pageParser })
  return {
    api,
    ensureSession,
    importRun: createImportRun({ importService, parser: pageParser, uploadGate, onImported: () => undefined }),
    syncRun: createMusicSyncRun({
      gate: uploadGate,
      service: createMusicSyncService({ api, musicKit }),
      onPublished: () => undefined,
    }),
  }
}

/**
 * The same import run, with the session made sure of before anything that
 * reaches the server. Reading a picked file does: the inspection loads the
 * current collections and records the funnel step. Picking files is the
 * listener's first deliberate server action on that page, so creation stays
 * lazy.
 */
export function importRunWithSession(run: ImportRun, ensureSession: () => Promise<void>, onError: () => void): ImportRun {
  const after = (action: () => void) => {
    ensureSession().then(action, onError)
  }
  return {
    ...run,
    take: (file) => after(() => run.take(file)),
    reviewAgain: () => after(() => run.reviewAgain()),
    tryAgain: () => after(() => run.tryAgain()),
    upload: () => after(() => run.upload()),
    retry: () => after(() => run.retry()),
  }
}

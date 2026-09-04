// The page side of the parser protocol: the same calls as spotify-parser.ts
// and diagnostics.ts, run in a Worker so a large history never blocks the UI.

import type { ExportDiagnostics } from './diagnostics'
import type { ExportInventory } from './snapshot'
import type { ParseProgress, ParseResult } from './spotify-parser'
import { UnreadableExportError } from './unreadable-error'
import {
  isWorkerResponse,
  type MessagePortLike,
  type ParseRequestOptions,
  type WorkerFailure,
  type WorkerRequest,
  type WorkerResponse,
} from './worker-protocol'

export type WorkerHandle = MessagePortLike & { terminate?: () => void }

export type ClientCallOptions = {
  signal?: AbortSignal
}

export type ClientParseOptions = ParseRequestOptions & ClientCallOptions & {
  onProgress?: (progress: ParseProgress) => void
}

export type ParserWorkerClient = {
  inspect(file: Blob, options?: ClientCallOptions): Promise<ExportInventory>
  parse(file: Blob, options: ClientParseOptions): Promise<ParseResult>
  diagnose(file: Blob, options?: ClientCallOptions): Promise<ExportDiagnostics>
  /** Rejects every pending call with an AbortError and terminates the Worker. */
  terminate(): void
}

export function spawnParserWorker(): Worker {
  return new Worker(new URL('./parser.worker.ts', import.meta.url), { type: 'module' })
}

const abortError = (reason?: unknown): unknown =>
  reason ?? new DOMException('The operation was aborted.', 'AbortError')

function reviveFailure(failure: WorkerFailure): unknown {
  if (failure.name === 'UnreadableExportError' && failure.inventory !== undefined) {
    return new UnreadableExportError(failure.file ?? null, failure.inventory)
  }
  if (failure.name === 'AbortError') return new DOMException(failure.message, 'AbortError')
  const error = new Error(failure.message)
  error.name = failure.name
  return error
}

type Pending = {
  resolve: (result: WorkerResponse & { type: 'result' }) => void
  reject: (reason: unknown) => void
  onProgress?: (progress: ParseProgress) => void
  cleanup: () => void
}

export function createParserWorkerClient(port: WorkerHandle = spawnParserWorker()): ParserWorkerClient {
  let nextId = 1
  const pending = new Map<number, Pending>()

  const listener = (event: { data: unknown }) => {
    const response = event.data
    if (!isWorkerResponse(response)) return
    const call = pending.get(response.id)
    if (call === undefined) return
    if (response.type === 'progress') {
      call.onProgress?.(response.progress)
      return
    }
    pending.delete(response.id)
    call.cleanup()
    if (response.type === 'result') call.resolve(response)
    else call.reject(reviveFailure(response.failure))
  }
  port.addEventListener('message', listener)

  function request(
    build: (id: number) => WorkerRequest,
    options: ClientCallOptions & { onProgress?: (progress: ParseProgress) => void },
  ): Promise<WorkerResponse & { type: 'result' }> {
    const { signal } = options
    if (signal?.aborted) return Promise.reject(abortError(signal.reason))
    const id = nextId
    nextId += 1
    return new Promise((resolve, reject) => {
      const onAbort = () => {
        pending.delete(id)
        port.postMessage({ type: 'abort', id } satisfies WorkerRequest)
        reject(abortError(signal?.reason))
      }
      pending.set(id, {
        resolve,
        reject,
        onProgress: options.onProgress,
        cleanup: () => signal?.removeEventListener('abort', onAbort),
      })
      signal?.addEventListener('abort', onAbort, { once: true })
      port.postMessage(build(id))
    })
  }

  return {
    async inspect(file, options = {}) {
      const response = await request((id) => ({ type: 'inspect', id, file }), options)
      return response.result as ExportInventory
    },
    async parse(file, options) {
      const response = await request(
        (id) => ({
          type: 'parse',
          id,
          file,
          options: { timeZone: options.timeZone, includePrivateSessions: options.includePrivateSessions },
        }),
        options,
      )
      return response.result as ParseResult
    },
    async diagnose(file, options = {}) {
      const response = await request((id) => ({ type: 'diagnose', id, file }), options)
      return response.result as ExportDiagnostics
    },
    terminate() {
      port.removeEventListener('message', listener)
      for (const [id, call] of pending) {
        pending.delete(id)
        call.cleanup()
        call.reject(abortError())
      }
      port.terminate?.()
    },
  }
}

// Messages between the page and the parser Worker. Blobs cross postMessage by
// reference (structured clone does not copy their bytes), so the archive is
// opened and read inside the Worker only.

import type { ExportDiagnostics } from './diagnostics'
import type { ExportInventory } from './snapshot'
import type { ParseProgress, ParseResult } from './spotify-parser'

export type ParseRequestOptions = {
  timeZone: string
  includePrivateSessions: boolean
}

export type WorkerRequest =
  | { type: 'inspect'; id: number; file: Blob }
  | { type: 'parse'; id: number; file: Blob; options: ParseRequestOptions }
  | { type: 'diagnose'; id: number; file: Blob }
  | { type: 'abort'; id: number }

export type WorkerFailure = {
  name: string
  message: string
  file?: string | null
  inventory?: ExportInventory
}

export type WorkerResponse =
  | { type: 'progress'; id: number; progress: ParseProgress }
  | { type: 'result'; id: number; result: ExportInventory | ParseResult | ExportDiagnostics }
  | { type: 'failure'; id: number; failure: WorkerFailure }

export type MessageListener = (event: { data: unknown }) => void

/** The slice of Worker / DedicatedWorkerGlobalScope / MessagePort the host and client use. */
export interface MessagePortLike {
  postMessage(message: unknown): void
  addEventListener(type: 'message', listener: MessageListener): void
  removeEventListener(type: 'message', listener: MessageListener): void
}

const isRecord = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null

export function isWorkerRequest(value: unknown): value is WorkerRequest {
  if (!isRecord(value) || typeof value.id !== 'number') return false
  switch (value.type) {
    case 'abort':
      return true
    case 'inspect':
    case 'diagnose':
      return value.file instanceof Blob
    case 'parse':
      return (
        value.file instanceof Blob &&
        isRecord(value.options) &&
        typeof value.options.timeZone === 'string' &&
        typeof value.options.includePrivateSessions === 'boolean'
      )
    default:
      return false
  }
}

export function isWorkerResponse(value: unknown): value is WorkerResponse {
  if (!isRecord(value) || typeof value.id !== 'number') return false
  switch (value.type) {
    case 'progress':
      return isRecord(value.progress)
    case 'result':
      return isRecord(value.result)
    case 'failure':
      return isRecord(value.failure) && typeof value.failure.name === 'string'
    default:
      return false
  }
}

// The Worker side of the parser protocol, kept free of Worker globals so a
// test can drive it through any message port.

import { diagnoseExport } from './diagnostics'
import { UnreadableExportError, inspectExport, parseExport } from './spotify-parser'
import { isWorkerRequest, type MessagePortLike, type WorkerFailure, type WorkerRequest, type WorkerResponse } from './worker-protocol'
import { openZipArchive } from './zip-reader'

export type ParserWorkerHost = {
  dispose(): void
}

function describeFailure(error: unknown): WorkerFailure {
  if (error instanceof UnreadableExportError) {
    return { name: error.name, message: error.message, file: error.file, inventory: error.inventory }
  }
  if (error instanceof Error) return { name: error.name, message: error.message }
  return { name: 'Error', message: 'The export could not be processed.' }
}

export function createParserWorkerHost(port: MessagePortLike): ParserWorkerHost {
  const controllers = new Map<number, AbortController>()
  const post = (response: WorkerResponse) => port.postMessage(response)

  async function serve(request: Exclude<WorkerRequest, { type: 'abort' }>): Promise<void> {
    const controller = new AbortController()
    controllers.set(request.id, controller)
    const { signal } = controller
    try {
      const archive = await openZipArchive(request.file)
      let result: WorkerResponse & { type: 'result' }
      if (request.type === 'inspect') {
        result = { type: 'result', id: request.id, result: await inspectExport(archive, { signal }) }
      } else if (request.type === 'parse') {
        result = {
          type: 'result',
          id: request.id,
          result: await parseExport(archive, {
            ...request.options,
            signal,
            onProgress: (progress) => post({ type: 'progress', id: request.id, progress }),
          }),
        }
      } else {
        result = { type: 'result', id: request.id, result: await diagnoseExport(archive, { signal }) }
      }
      post(result)
    } catch (error) {
      post({ type: 'failure', id: request.id, failure: describeFailure(error) })
    } finally {
      controllers.delete(request.id)
    }
  }

  const listener = (event: { data: unknown }) => {
    const request = event.data
    if (!isWorkerRequest(request)) return
    if (request.type === 'abort') {
      controllers.get(request.id)?.abort()
      return
    }
    void serve(request)
  }
  port.addEventListener('message', listener)

  return {
    dispose() {
      port.removeEventListener('message', listener)
      for (const controller of controllers.values()) controller.abort()
      controllers.clear()
    },
  }
}

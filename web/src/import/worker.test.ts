import { describe, expect, it } from 'vitest'
import { UnreadableExportError, type ParseProgress } from './spotify-parser'
import { createParserWorkerClient } from './worker-client'
import { createParserWorkerHost } from './worker-host'
import type { MessageListener, MessagePortLike, WorkerRequest } from './worker-protocol'
import { readExpected, readFixtureArchive } from '../test/listening-export-fixtures'

/** Two ends of an in-memory channel: messages are delivered asynchronously, like a real port. */
class FakePort implements MessagePortLike {
  peer!: FakePort
  readonly sent: unknown[] = []
  terminated = false
  private readonly listeners = new Map<string, Set<(event: never) => void>>()

  postMessage(message: unknown): void {
    this.sent.push(message)
    const { peer } = this
    setTimeout(() => peer.emit('message', { data: message }), 0)
  }

  addEventListener(type: string, listener: (event: never) => void): void {
    let set = this.listeners.get(type)
    if (!set) this.listeners.set(type, (set = new Set()))
    set.add(listener)
  }

  removeEventListener(type: string, listener: (event: never) => void): void {
    this.listeners.get(type)?.delete(listener)
  }

  /** What the browser does when the Worker script fails to load or throws at top level. */
  emit(type: string, event: unknown): void {
    for (const listener of [...(this.listeners.get(type) ?? [])]) (listener as (event: unknown) => void)(event)
  }

  terminate(): void {
    this.terminated = true
  }
}

function connect() {
  const pageSide = new FakePort()
  const workerSide = new FakePort()
  pageSide.peer = workerSide
  workerSide.peer = pageSide
  const host = createParserWorkerHost(workerSide)
  const client = createParserWorkerClient(pageSide)
  return { pageSide, workerSide, host, client }
}

const lagos = { timeZone: 'Africa/Lagos', includePrivateSessions: false }

describe('parser worker protocol', () => {
  it('parses through the worker host with progress events and the same result as a direct parse', async () => {
    const { client } = connect()
    const events: ParseProgress[] = []
    const result = await client.parse(readFixtureArchive('extended-basic'), {
      ...lagos,
      onProgress: (progress) => events.push(progress),
    })
    const expected = readExpected('extended-basic', 'default')
    expect(result.inventory).toEqual(expected.inventory)
    expect(result.snapshot).toEqual(expected.snapshot)
    expect(result.stats).toEqual({ podcastOrAudiobook: 0, localFile: 0, privateSession: 0, badTimestamp: 3, privatePlays: 0 })
    expect(events[0]?.stage).toBe('listing')
    expect(events.at(-1)?.stage).toBe('complete')
    expect(events.filter((event) => event.stage === 'reading')).toHaveLength(expected.inventory.read.length)
  })

  it('serves inspect and diagnose calls', async () => {
    const { client } = connect()
    const inventory = await client.inspect(readFixtureArchive('account-basic'))
    expect(inventory).toEqual(readExpected('account-basic', 'default').inventory)
    const diagnostics = await client.diagnose(readFixtureArchive('account-basic'))
    expect(diagnostics.source).toBe('spotify_export')
    expect(diagnostics.files.map((file) => file.path)).toEqual(
      [...inventory.read.map((file) => file.path), ...inventory.ignored.map((file) => file.path)].sort(),
    )
  })

  it('revives an unreadable failure with its file and inventory', async () => {
    const { client } = connect()
    const failure = await client.parse(readFixtureArchive('extended-malformed'), lagos).then(
      () => null,
      (error: unknown) => error,
    )
    expect(failure).toBeInstanceOf(UnreadableExportError)
    const expected = readExpected('extended-malformed', 'default')
    expect((failure as UnreadableExportError).file).toBe(expected.error?.file)
    expect((failure as UnreadableExportError).inventory).toEqual(expected.inventory)
  })

  it('aborts a call through the abort message and rejects with AbortError', async () => {
    const { client, pageSide, workerSide } = connect()
    const controller = new AbortController()
    const pending = client.parse(readFixtureArchive('extended-basic'), { ...lagos, signal: controller.signal })
    controller.abort()
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' })
    const abort = pageSide.sent.find((message) => (message as WorkerRequest).type === 'abort') as WorkerRequest | undefined
    expect(abort).toEqual({ type: 'abort', id: 1 })
    // The host must actually honour the abort: it answers the aborted id with
    // an AbortError failure and never with a result. The client drops that late
    // failure, and later calls still work.
    await new Promise((resolve) => setTimeout(resolve, 20))
    const answers = workerSide.sent.filter((message) => (message as { id?: number }).id === 1)
    expect(answers).toContainEqual(
      expect.objectContaining({ type: 'failure', id: 1, failure: expect.objectContaining({ name: 'AbortError' }) }),
    )
    expect(answers.some((message) => (message as { type?: string }).type === 'result')).toBe(false)
    const inventory = await client.inspect(readFixtureArchive('extended-basic'))
    expect(inventory.package).toBe('spotify_extended')
  })

  it('rejects a call whose signal is already aborted without sending anything', async () => {
    const { client, pageSide } = connect()
    const controller = new AbortController()
    controller.abort()
    await expect(client.inspect(readFixtureArchive('extended-basic'), { signal: controller.signal })).rejects.toMatchObject({
      name: 'AbortError',
    })
    expect(pageSide.sent).toEqual([])
  })

  it('ignores messages that are not part of the protocol on either side', async () => {
    const { client, pageSide, workerSide } = connect()
    pageSide.postMessage({ hello: 'page' })
    workerSide.postMessage({ type: 'result', id: 99 })
    workerSide.postMessage('text')
    await new Promise((resolve) => setTimeout(resolve, 10))
    expect(workerSide.sent).toHaveLength(2)
    const inventory = await client.inspect(readFixtureArchive('account-empty-playlist'))
    expect(inventory.package).toBe('spotify_account')
  })

  it('fails every pending call with a non-abort error when the Worker itself errors, then terminates it', async () => {
    const { client, pageSide } = connect()
    const pending = client.parse(readFixtureArchive('extended-basic'), lagos)
    const inspecting = client.inspect(readFixtureArchive('account-basic'))
    pageSide.emit('error', new Event('error'))

    await expect(pending).rejects.toThrow('worker_failed')
    await expect(pending).rejects.not.toMatchObject({ name: 'AbortError' })
    await expect(inspecting).rejects.toThrow('worker_failed')
    expect(pageSide.terminated).toBe(true)
    // The Worker is gone: a later call cannot hang waiting for it either.
    await expect(client.diagnose(readFixtureArchive('account-basic'))).rejects.toThrow('worker_failed')
    expect(pageSide.sent.filter((message) => (message as WorkerRequest).type === 'diagnose')).toHaveLength(0)
  })

  it('treats a messageerror the same way', async () => {
    const { client, pageSide } = connect()
    const pending = client.inspect(readFixtureArchive('extended-basic'))
    pageSide.emit('messageerror', new Event('messageerror'))
    await expect(pending).rejects.toThrow('worker_failed')
    expect(pageSide.terminated).toBe(true)
  })

  it('terminate rejects pending calls and terminates the worker', async () => {
    const { client, pageSide } = connect()
    const pending = client.parse(readFixtureArchive('extended-basic'), lagos)
    client.terminate()
    await expect(pending).rejects.toMatchObject({ name: 'AbortError' })
    expect(pageSide.terminated).toBe(true)
  })
})

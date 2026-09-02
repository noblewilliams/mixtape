import { Uint8ArrayReader, Uint8ArrayWriter, ZipWriter } from '@zip.js/zip.js'

const encoder = new TextEncoder()

export type ZipEntrySpec = {
  path: string
  /** Pretty-printed JSON body, like the fixture builder writes. */
  json?: unknown
  text?: string
  bytes?: Uint8Array
  directory?: boolean
  /** Write sizes and CRC in a trailing data descriptor (streaming writers do this). */
  dataDescriptor?: boolean
}

/** A ZIP built in memory with zip.js; entries are written in the given order. */
export async function buildZipBlob(entries: ZipEntrySpec[]): Promise<Blob> {
  // Uint8ArrayWriter rather than BlobWriter for the same reason: the Blob is
  // assembled here from the finished bytes.
  const writer = new ZipWriter(new Uint8ArrayWriter(), {
    useWebWorkers: false,
    useCompressionStream: true,
    lastModDate: new Date(Date.UTC(2026, 0, 1)),
  })
  for (const entry of entries) {
    if (entry.directory === true) {
      await writer.add(entry.path, undefined, { directory: true })
      continue
    }
    // Uint8ArrayReader rather than TextReader: TextReader goes through a Blob,
    // and jsdom's Blob has no stream().
    const bytes =
      entry.bytes ??
      encoder.encode(entry.json !== undefined ? `${JSON.stringify(entry.json, null, 2)}\n` : (entry.text ?? ''))
    await writer.add(
      entry.path,
      new Uint8ArrayReader(bytes),
      entry.dataDescriptor === undefined ? {} : { dataDescriptor: entry.dataDescriptor },
    )
  }
  return new Blob([await writer.close()], { type: 'application/zip' })
}

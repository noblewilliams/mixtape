import { BlobReader, Uint8ArrayWriter, ZipReader, type FileEntry } from '@zip.js/zip.js'

export type ArchiveEntry = {
  /** Entry path as stored in the central directory, forward slashes. */
  path: string
  /** Uncompressed size from the central directory. */
  bytes: number
}

export type ReadTextOptions = {
  signal?: AbortSignal
}

/**
 * A ZIP archive opened by its central directory. `entries()` costs nothing
 * beyond that directory read; each `readText` decompresses exactly one entry.
 */
export interface ExportArchive {
  /** Every file entry (directory entries are skipped), in archive order. */
  entries(): Promise<ArchiveEntry[]>
  /** One entry decoded as UTF-8: a leading BOM is dropped, malformed bytes throw. */
  readText(path: string, options?: ReadTextOptions): Promise<string>
}

// No zip.js worker pool (the parser already runs in our own Worker, or in a
// test) and the platform's DecompressionStream('deflate-raw') everywhere. The
// non-native fallback in zip.js 2.9 is a WebAssembly module fetched at
// runtime, which a bundled page, a Worker, and vitest would each resolve
// differently; the native stream behaves the same in all three.
const CODEC_OPTIONS = { useWebWorkers: false, useCompressionStream: true } as const

const utf8 = new TextDecoder('utf-8', { fatal: true, ignoreBOM: false })

/** Strict UTF-8: throws a TypeError on malformed input; a leading BOM is dropped. */
export function decodeUtf8(bytes: Uint8Array): string {
  return utf8.decode(bytes)
}

export async function openZipArchive(file: Blob): Promise<ExportArchive> {
  const reader = new ZipReader(new BlobReader(file), CODEC_OPTIONS)
  const files = new Map<string, FileEntry>()
  const entries: ArchiveEntry[] = []
  for (const entry of await reader.getEntries()) {
    if (entry.directory) continue
    if (!files.has(entry.filename)) files.set(entry.filename, entry)
    entries.push({ path: entry.filename, bytes: entry.uncompressedSize })
  }
  return {
    entries: () => Promise.resolve(entries.map((entry) => ({ ...entry }))),
    async readText(path, options = {}) {
      const entry = files.get(path)
      if (entry === undefined) throw new Error('entry is not in the archive')
      options.signal?.throwIfAborted()
      const bytes = await entry.getData(new Uint8ArrayWriter(), { ...CODEC_OPTIONS, signal: options.signal })
      options.signal?.throwIfAborted()
      return decodeUtf8(bytes)
    },
  }
}

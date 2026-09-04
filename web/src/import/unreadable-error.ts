import type { ExportInventory } from './snapshot'

/** The parser's fail-closed error: which allow-listed file broke, and the inventory read so far. */
export class UnreadableExportError extends Error {
  readonly code = 'unreadable' as const
  /** Base name of the first broken allow-listed file in path order; null when there is none to read. */
  readonly file: string | null
  readonly inventory: ExportInventory

  constructor(file: string | null, inventory: ExportInventory) {
    super(file === null ? 'The archive holds no Spotify export files.' : 'A Spotify export file could not be read.')
    this.name = 'UnreadableExportError'
    this.file = file
    this.inventory = inventory
  }
}

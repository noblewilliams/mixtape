// The text a listener can copy when an archive fails closed: one line per
// entry with its path, byte size, and row count or why it has none. Built
// from the diagnostics and the inventory alone, so it never carries a value.

import type { ExportDiagnostics } from './diagnostics'
import type { ExportInventory } from './snapshot'

const UNITS = ['B', 'KB', 'MB', 'GB'] as const

export function formatBytes(bytes: number): string {
  let value = Math.max(0, bytes)
  let unit = 0
  while (value >= 1024 && unit < UNITS.length - 1) {
    value /= 1024
    unit += 1
  }
  const rounded = unit === 0 ? Math.round(value) : Number(value.toFixed(1))
  return `${rounded} ${UNITS[unit]}`
}

export function formatCount(value: number): string {
  return value.toLocaleString('en-US')
}

export function formatDiagnosticsReport(diagnostics: ExportDiagnostics, inventory: ExportInventory | null): string {
  const read = new Set(inventory?.read.map((file) => file.path) ?? [])
  const ignored = new Set(inventory?.ignored.map((file) => file.path) ?? [])
  const lines = diagnostics.files.map((file) => {
    const status =
      file.rows !== null
        ? `rows ${formatCount(file.rows)}`
        : read.has(file.path)
          ? 'unreadable'
          : ignored.has(file.path) || inventory === null
            ? 'ignored'
            : 'not read'
    return `${file.path} · ${formatBytes(file.bytes)} · ${status}`
  })
  return [`source: ${diagnostics.source}`, ...lines, `parser ${diagnostics.parserVersion}`].join('\n')
}

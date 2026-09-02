import { readFileSync } from 'node:fs'

// Loads server/.dev.vars the way scripts/retitle-sessions.ts and
// scripts/analyze-previews.ts do inline: KEY=value lines, comments skipped,
// one layer of matching surrounding quotes stripped — a quoted DATABASE_URL
// would otherwise reach neon() with the quote characters still attached,
// which throws with the full connection string (credentials included)
// embedded in the error message.
export function loadDevVars(file: URL = new URL('../../.dev.vars', import.meta.url)): Record<string, string> {
  const out: Record<string, string> = {}
  for (const line of readFileSync(file, 'utf8').split('\n')) {
    const i = line.indexOf('=')
    if (i > 0 && !line.startsWith('#')) {
      const key = line.slice(0, i)
      let value = line.slice(i + 1).trim()
      if (
        value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))
      ) {
        value = value.slice(1, -1)
      }
      out[key] = value
    }
  }
  return out
}

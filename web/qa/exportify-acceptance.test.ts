// Opt-in local acceptance. Never logs names, identifiers, or archive contents.
// MIXTAPE_ACCEPTANCE_ARCHIVE selects a user-supplied export outside the repo.
import { readFileSync, writeFileSync } from 'node:fs'
import { createHash } from 'node:crypto'
import { basename } from 'node:path'
import { it } from 'vitest'
import { openExportArchive } from '../src/import/zip-reader'
import { parseExport } from '../src/import/spotify-parser'
import { canonicalize } from '../src/import/canonical'
const path = process.env.MIXTAPE_ACCEPTANCE_ARCHIVE
it.skipIf(!path)('validates a real export locally without logging music data', async () => {
  try {
    const bytes = readFileSync(path!)
    const file = new File([bytes], basename(path!))
    const result = await parseExport(await openExportArchive(file), {timeZone:'UTC', includePrivateSessions:false})
    const snapshot = result.snapshot
    if (snapshot.package !== 'spotify_exportify' || !snapshot.playlists.length || snapshot.days.length || snapshot.library.length) throw new Error()
    const digest = createHash('sha256').update(JSON.stringify(canonicalize(snapshot))).digest('hex')
    const report = JSON.stringify({package:snapshot.package,files:result.inventory.read.length,tracks:snapshot.tracks.length,playlists:snapshot.playlists.length,entries:snapshot.playlists.reduce((n,p)=>n+p.entries.length,0),unresolved:snapshot.unresolved.rows,digest})
    if (process.env.MIXTAPE_ACCEPTANCE_REPORT) writeFileSync(process.env.MIXTAPE_ACCEPTANCE_REPORT, report, {mode:0o600})
  } catch { throw new Error('Export acceptance failed. No music data logged.') }
})

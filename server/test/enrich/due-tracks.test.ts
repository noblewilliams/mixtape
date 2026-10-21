import { describe, it, expect } from 'vitest'
import { sql } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import { trackFeatures, trackMeanings, tracks } from '../../src/db/schema'
import { dueTracks, FRONT_OF_QUEUE_PRIORITY } from '../../src/enrich/runner'

const UNIT = Array.from({ length: 1024 }, (_, i) => (i === 0 ? 1 : 0))

describe('dueTracks', () => {
  it('returns due rows highest priority first, FRONT_OF_QUEUE_PRIORITY ahead of an import, with skip flags', async () => {
    const db = await createTestDb()
    const [backlog] = await db.insert(tracks).values({ appleId: 'a0', title: 'Backlog', artist: 'A' }).returning()
    const [imported] = await db.insert(tracks).values({ appleId: 'a1', title: 'Import', artist: 'A', enrichPriority: 5 }).returning()
    const [front] = await db.insert(tracks).values({ appleId: 'a2', title: 'Fill', artist: 'A', enrichPriority: FRONT_OF_QUEUE_PRIORITY }).returning()
    const [done] = await db.insert(tracks).values({ appleId: 'a3', title: 'Done', artist: 'A', enrichPriority: FRONT_OF_QUEUE_PRIORITY + 1 }).returning()
    await db.insert(trackFeatures).values({ trackId: done.id, tempo: 100, source: 'reccobeats' })
    await db.insert(trackMeanings).values({ trackId: done.id, embedding: UNIT, lyricsSource: 'lrclib' })
    await db.insert(trackFeatures).values({ trackId: imported.id, tempo: 100, source: 'reccobeats' })

    const due = await dueTracks(db, 10)

    expect(due.map((d) => d.track.id)).toEqual([front.id, imported.id, backlog.id])
    expect(due[1].skip).toEqual({ features: true, meaning: false })
    expect(due[0].skip).toEqual({ features: false, meaning: false })
    expect(due[0].track.artistKeys).toEqual(['a'])
  })

  it('narrows to the given filter and honours the limit', async () => {
    const db = await createTestDb()
    const rows = await db.insert(tracks).values([
      { appleId: 'b0', title: 'One', artist: 'Tems', enrichPriority: 3 },
      { appleId: 'b1', title: 'Two', artist: 'Tems', enrichPriority: 2 },
      { appleId: 'b2', title: 'Three', artist: 'Other', enrichPriority: 9 },
    ]).returning()

    const due = await dueTracks(db, 1, sql`t.artist_keys && ARRAY['tems']::text[]`)

    expect(due.map((d) => d.track.id)).toEqual([rows[0].id])
  })
})

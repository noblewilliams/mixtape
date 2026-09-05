import { readFileSync } from 'node:fs'
import { eq, sql } from 'drizzle-orm'
import { describe, expect, it } from 'vitest'
import { appleIsrcLookups, tracks } from '../../src/db/schema'
import { createTestDb } from '../helpers/db'

describe('Apple ISRC migration', () => {
  it('upgrades existing catalog rows without guessing a historical storefront', async () => {
    const db = await createTestDb()
    await db.execute(sql`DROP TABLE apple_isrc_lookups`)
    await db.execute(sql`ALTER TABLE tracks DROP COLUMN apple_catalog_storefront`)
    await db.execute(sql`INSERT INTO tracks (apple_id, title, artist) VALUES ('123', 'Existing', 'Artist')`)
    const migration = readFileSync(new URL('../../drizzle/0023_apple_isrc_linking.sql', import.meta.url), 'utf8')
    for (const statement of migration.split('--> statement-breakpoint')) {
      if (statement.trim()) await db.execute(sql.raw(statement))
    }
    expect(await db.select().from(tracks)).toMatchObject([{ appleId: '123', appleCatalogStorefront: null, title: 'Existing' }])
    expect(await db.select().from(appleIsrcLookups)).toEqual([])
    await expect(db.execute(sql`UPDATE tracks SET apple_catalog_storefront = 'US'`)).rejects.toThrow()
  })

  it('constrains retry identities and cascades only with the canonical track', async () => {
    const db = await createTestDb()
    const [track] = await db.insert(tracks).values({ title: 'Song', artist: 'Artist' }).returning()
    const value = { trackId: track.id, storefront: 'ng', isrc: 'USUG11904206', leaseToken: crypto.randomUUID() }
    await db.insert(appleIsrcLookups).values(value)
    await expect(db.insert(appleIsrcLookups).values(value)).rejects.toThrow()
    await expect(db.insert(appleIsrcLookups).values({ ...value, storefront: 'invalid' })).rejects.toThrow()
    await expect(db.insert(appleIsrcLookups).values({ ...value, isrc: 'invalid' })).rejects.toThrow()
    await expect(db.insert(appleIsrcLookups).values({ ...value, trackId: crypto.randomUUID() })).rejects.toThrow()
    await db.delete(tracks).where(eq(tracks.id, track.id))
    expect(await db.select().from(appleIsrcLookups)).toEqual([])
  })
})

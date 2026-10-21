import { describe, it, expect } from 'vitest'
import { sql } from 'drizzle-orm'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { createTestDb } from '../helpers/db'
import { funnelEvents, user } from '../../src/db/schema'

const MIGRATION = fileURLToPath(new URL('../../drizzle/0042_catalogue_filled_funnel_event.sql', import.meta.url))

async function dbWithUser() {
  const db = await createTestDb()
  await db.insert(user).values({ id: 'u1', name: 'u1', email: 'u1@example.com', emailVerified: false, createdAt: new Date(), updatedAt: new Date() })
  return db
}

// Migration 0042: funnel_events.type admits 'catalogue_filled' (the DJ
// loop's Apple fill, spec 2026-10-21 everyone-gets-a-mix step 2).
describe('funnel_events.type catalogue_filled', () => {
  it("accepts 'catalogue_filled' next to the existing types", async () => {
    const db = await dbWithUser()
    await db.insert(funnelEvents).values({ userId: 'u1', type: 'catalogue_filled', surface: 'web' })
    await db.insert(funnelEvents).values({ userId: 'u1', type: 'first_mix_made', surface: 'ios' })
    expect(await db.select().from(funnelEvents)).toHaveLength(2)
  })

  it('still rejects an unknown type', async () => {
    const db = await dbWithUser()
    const err = await db
      .execute(sql`INSERT INTO funnel_events (user_id, type, surface) VALUES ('u1', 'bogus', 'web')`)
      .then(() => undefined, (e: unknown) => e as { cause?: { constraint?: string }; constraint?: string })
    expect(err?.cause?.constraint ?? err?.constraint).toBe('funnel_events_type_check')
  })

  it('the migration only swaps that one constraint', async () => {
    const statements = (await readFile(MIGRATION, 'utf8'))
      .split('--> statement-breakpoint')
      .map((s) => s.trim())
      .filter((s) => s !== '')
    expect(statements).toHaveLength(2)
    expect(statements[0]).toMatch(/^ALTER TABLE "funnel_events" DROP CONSTRAINT "funnel_events_type_check";?$/)
    expect(statements[1]).toMatch(/^ALTER TABLE "funnel_events" ADD CONSTRAINT "funnel_events_type_check" CHECK/)
    expect(statements[1]).toContain("'catalogue_filled'")
    expect(statements[1]).toContain("'account_linked_existing'")
  })
})

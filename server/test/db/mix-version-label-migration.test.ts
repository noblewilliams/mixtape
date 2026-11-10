import { describe, it, expect } from 'vitest'
import { sql } from 'drizzle-orm'
import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { createTestDb } from '../helpers/db'

const MIGRATION = fileURLToPath(new URL('../../drizzle/0049_mix_version_label.sql', import.meta.url))
const JOURNAL = fileURLToPath(new URL('../../drizzle/meta/_journal.json', import.meta.url))
const SNAPSHOT = (n: string) => fileURLToPath(new URL(`../../drizzle/meta/${n}_snapshot.json`, import.meta.url))

// Migration 0049: mix_versions.not_personal, the label a version stood with,
// so a restore brings it back (spec 2026-11-09 add-your-music-loop,
// decision 4). Nullable with no default: versions written before it hold no
// label, and a restore of one leaves the session's flag as it is.
describe('migration 0049 mix version label', () => {
  it('only adds the nullable column', async () => {
    const statements = (await readFile(MIGRATION, 'utf8')).split('--> statement-breakpoint').map((s) => s.trim()).filter(Boolean)
    expect(statements).toEqual(['ALTER TABLE "mix_versions" ADD COLUMN "not_personal" boolean;'])
  })

  it('migrates to a nullable boolean with no default', async () => {
    const db = await createTestDb()
    const res = await db.execute(sql`
      SELECT data_type, is_nullable, column_default FROM information_schema.columns
      WHERE table_name = 'mix_versions' AND column_name = 'not_personal'`)
    expect(res.rows).toEqual([{ data_type: 'boolean', is_nullable: 'YES', column_default: null }])
  })

  it('is journalled right after 0048, with a chained snapshot', async () => {
    const journal = JSON.parse(await readFile(JOURNAL, 'utf8')) as { entries: { idx: number; tag: string }[] }
    const at = journal.entries.findIndex((e) => e.idx === 49)
    expect(journal.entries[at]?.tag).toBe('0049_mix_version_label')
    expect(journal.entries[at - 1]?.idx).toBe(48)
    const prev = JSON.parse(await readFile(SNAPSHOT('0048'), 'utf8')) as { id: string }
    const next = JSON.parse(await readFile(SNAPSHOT('0049'), 'utf8')) as {
      prevId: string
      tables: Record<string, { columns: Record<string, { type: string; notNull: boolean; default?: unknown }> }>
    }
    expect(next.prevId).toBe(prev.id)
    const column = next.tables['public.mix_versions'].columns.not_personal
    expect(column).toMatchObject({ type: 'boolean', notNull: false })
    expect(column.default).toBeUndefined()
  })
})

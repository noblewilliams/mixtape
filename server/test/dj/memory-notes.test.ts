import { describe, it, expect } from 'vitest'
import { eq } from 'drizzle-orm'
import { createTestDb } from '../helpers/db'
import { seedUser } from '../helpers/listening-fixtures'
import { djMemories } from '../../src/db/schema'
import { insertMemoryNote, MAX_MEMORY_NOTES, MAX_MEMORY_NOTE_LENGTH } from '../../src/dj/memory-notes'
import { MAX_MEMORY_NOTES as LOOP_MAX_MEMORY_NOTES } from '../../src/dj/loop'
import { rememberPreferenceInputSchema } from '../../src/dj/contracts'

describe('insertMemoryNote', () => {
  it('saves a trimmed note and reports saved', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    expect(await insertMemoryNote(db, 'u1', '  never play Artist X  ')).toBe('saved')
    const rows = await db.select().from(djMemories).where(eq(djMemories.userId, 'u1'))
    expect(rows.map((r) => r.note)).toEqual(['never play Artist X'])
  })

  it('reports duplicate for an exact repeat and writes no second row', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await insertMemoryNote(db, 'u1', 'loves amapiano')
    expect(await insertMemoryNote(db, 'u1', 'loves amapiano ')).toBe('duplicate')
    expect(await db.select().from(djMemories).where(eq(djMemories.userId, 'u1'))).toHaveLength(1)
  })

  it('reports capped at MAX_MEMORY_NOTES and writes nothing', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await db.insert(djMemories).values(Array.from({ length: MAX_MEMORY_NOTES }, (_, i) => ({ userId: 'u1', note: `note ${i}` })))
    expect(await insertMemoryNote(db, 'u1', 'one too many')).toBe('capped')
    expect(await db.select().from(djMemories).where(eq(djMemories.userId, 'u1'))).toHaveLength(MAX_MEMORY_NOTES)
  })

  it('reports empty for a whitespace-only note and writes nothing', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    expect(await insertMemoryNote(db, 'u1', '   ')).toBe('empty')
    expect(await db.select().from(djMemories).where(eq(djMemories.userId, 'u1'))).toHaveLength(0)
  })

  it('caps a note at MAX_MEMORY_NOTE_LENGTH characters', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    expect(await insertMemoryNote(db, 'u1', 'x'.repeat(MAX_MEMORY_NOTE_LENGTH + 40))).toBe('saved')
    const [row] = await db.select().from(djMemories).where(eq(djMemories.userId, 'u1'))
    expect(row.note).toHaveLength(MAX_MEMORY_NOTE_LENGTH)
  })

  it('caps by code point: an emoji at the cut survives whole, never as a lone surrogate', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    const kept = `${'x'.repeat(MAX_MEMORY_NOTE_LENGTH - 1)}😀`
    expect(await insertMemoryNote(db, 'u1', `${kept}tail`)).toBe('saved')
    const [row] = await db.select().from(djMemories).where(eq(djMemories.userId, 'u1'))
    expect(row.note).toBe(kept)
    expect(Array.from(row.note)).toHaveLength(MAX_MEMORY_NOTE_LENGTH)
  })

  it('scopes the cap and the duplicate check to the user', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await seedUser(db, 'u2')
    await db.insert(djMemories).values(Array.from({ length: MAX_MEMORY_NOTES }, (_, i) => ({ userId: 'u2', note: `note ${i}` })))
    expect(await insertMemoryNote(db, 'u1', 'note 0')).toBe('saved')
  })

  // The loop's tool schema and the helper's cap are the same number, so a
  // note the model may send is never silently clipped by the helper.
  it('agrees with the loop: MAX_MEMORY_NOTES is the loop constant and the tool schema caps at MAX_MEMORY_NOTE_LENGTH', () => {
    expect(LOOP_MAX_MEMORY_NOTES).toBe(MAX_MEMORY_NOTES)
    expect(rememberPreferenceInputSchema.safeParse({ note: 'x'.repeat(MAX_MEMORY_NOTE_LENGTH) }).success).toBe(true)
    expect(rememberPreferenceInputSchema.safeParse({ note: 'x'.repeat(MAX_MEMORY_NOTE_LENGTH + 1) }).success).toBe(false)
  })
})

import { describe, it, expect } from 'vitest'
import { createTestDb, type TestDb } from '../helpers/db'
import { funnelEvents } from '../../src/db/schema'
import { computeFunnelReport, formatFunnelReport, FUNNEL_ORDER } from '../../scripts/funnel-report'
import { seedUser } from '../helpers/listening-fixtures'

type Type = typeof funnelEvents.$inferInsert['type']

const at = (day: number) => new Date(Date.UTC(2026, 8, day, 12))

async function event(db: TestDb, userId: string, type: Type, createdAt: Date, surface: 'ios' | 'web' = 'ios') {
  await db.insert(funnelEvents).values({ userId, type, surface, createdAt })
}

describe('computeFunnelReport', () => {
  it('counts distinct users per step in funnel order, converts step to step, and takes the median request-to-import days', async () => {
    const db = await createTestDb()
    for (const id of ['u1', 'u2', 'u3', 'u4']) await seedUser(db, id)
    // u1: full funnel, imports 2 days after requesting (repeat events count once).
    await event(db, 'u1', 'chose_spotify', at(1))
    await event(db, 'u1', 'chose_spotify', at(1), 'web')
    await event(db, 'u1', 'marked_requested', at(1))
    await event(db, 'u1', 'interview_completed', at(1))
    await event(db, 'u1', 'file_inspected', at(3))
    await event(db, 'u1', 'import_completed', at(3))
    await event(db, 'u1', 'import_completed', at(5))
    await event(db, 'u1', 'first_personal_mix', at(3))
    await event(db, 'u1', 'first_output', at(3))
    // u2: requested, imported 6 days later, nothing after.
    await event(db, 'u2', 'chose_spotify', at(2))
    await event(db, 'u2', 'marked_requested', at(2))
    await event(db, 'u2', 'import_completed', at(8))
    // u3: chose and requested only.
    await event(db, 'u3', 'chose_spotify', at(2))
    await event(db, 'u3', 'marked_requested', at(4))
    // u4: imported without ever marking (no median contribution, no conversion credit from marked_requested).
    await event(db, 'u4', 'import_completed', at(9))

    const report = await computeFunnelReport(db)
    expect(FUNNEL_ORDER).toEqual([
      'chose_spotify', 'marked_requested', 'interview_completed', 'file_inspected',
      'import_completed', 'first_personal_mix', 'first_output',
    ])
    expect(report.steps).toEqual([
      { type: 'chose_spotify', users: 3 },
      { type: 'marked_requested', users: 3 },
      { type: 'interview_completed', users: 1 },
      { type: 'file_inspected', users: 1 },
      { type: 'import_completed', users: 3 },
      { type: 'first_personal_mix', users: 1 },
      { type: 'first_output', users: 1 },
    ])
    expect(report.conversions).toEqual([
      { from: 'chose_spotify', to: 'marked_requested', fromUsers: 3, converted: 3, rate: 1 },
      { from: 'marked_requested', to: 'interview_completed', fromUsers: 3, converted: 1, rate: 1 / 3 },
      { from: 'interview_completed', to: 'file_inspected', fromUsers: 1, converted: 1, rate: 1 },
      { from: 'file_inspected', to: 'import_completed', fromUsers: 1, converted: 1, rate: 1 },
      { from: 'import_completed', to: 'first_personal_mix', fromUsers: 3, converted: 1, rate: 1 / 3 },
      { from: 'first_personal_mix', to: 'first_output', fromUsers: 1, converted: 1, rate: 1 },
    ])
    expect(report.requestToImport).toEqual({ users: 2, medianDays: 4 })
  })

  it('reports zeros and no median on an empty table', async () => {
    const db = await createTestDb()
    const report = await computeFunnelReport(db)
    expect(report.steps.every((s) => s.users === 0)).toBe(true)
    expect(report.conversions.every((c) => c.fromUsers === 0 && c.converted === 0 && c.rate === null)).toBe(true)
    expect(report.requestToImport).toEqual({ users: 0, medianDays: null })
  })

  it('formats counts only, one line per step and per conversion', async () => {
    const db = await createTestDb()
    await seedUser(db, 'u1')
    await event(db, 'u1', 'chose_spotify', at(1))
    const text = formatFunnelReport(await computeFunnelReport(db))
    expect(text).toContain('chose_spotify')
    expect(text).toContain('1')
    expect(text).not.toContain('u1')
    expect(text.split('\n').length).toBeGreaterThanOrEqual(FUNNEL_ORDER.length * 2)
  })
})

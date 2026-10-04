import { readFile } from 'node:fs/promises'
import { PGlite } from '@electric-sql/pglite'
import { expect, it } from 'vitest'
import { TAPE_CASE_COLORS } from '../../src/dj/tape-colors'

it('backfills existing mixes reproducibly and persists defaults for later inserts', async () => {
  const db = new PGlite()
  try {
    await db.exec(`CREATE TABLE dj_sessions (id uuid PRIMARY KEY);
      INSERT INTO dj_sessions VALUES
      ('00000000-0000-4000-8000-000000000001'),
      ('00000000-0000-4000-8000-000000000002');`)
    await db.exec(await readFile(new URL('../../drizzle/0033_tape_case_color.sql', import.meta.url), 'utf8'))
    const old = await db.query<{ case_color: string }>('SELECT case_color FROM dj_sessions ORDER BY id')
    expect(old.rows.map(row => row.case_color)).toEqual(['#5dab9c', '#27626d'])
    await db.exec(`INSERT INTO dj_sessions VALUES ('00000000-0000-4000-8000-000000000003');`)
    const first = await db.query<{ case_color: string }>('SELECT case_color FROM dj_sessions ORDER BY id')
    expect(TAPE_CASE_COLORS).toContain(first.rows[2].case_color)
    const reread = await db.query('SELECT case_color FROM dj_sessions ORDER BY id')
    expect(reread.rows).toEqual(first.rows)
  } finally {
    await db.close()
  }
})

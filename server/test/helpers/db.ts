import { PGlite } from '@electric-sql/pglite'
import { vector } from '@electric-sql/pglite-pgvector'
import { drizzle } from 'drizzle-orm/pglite'
import { migrate } from 'drizzle-orm/pglite/migrator'
import { onTestFinished } from 'vitest'
import { fileURLToPath } from 'node:url'
import * as schema from '../../src/db/schema'

const MIGRATIONS_DIR = fileURLToPath(new URL('../../drizzle', import.meta.url))

let template: File | Blob | undefined

export type TestDb = Awaited<ReturnType<typeof createTestDb>>

export async function createTestDb() {
  if (!template) {
    const seed = new PGlite({ extensions: { vector } })
    await migrate(drizzle(seed, { schema }), { migrationsFolder: MIGRATIONS_DIR })
    template = await seed.dumpDataDir('none')
    await seed.close()
  }
  const client = await PGlite.create({ loadDataDir: template, extensions: { vector } })
  onTestFinished(() => client.close())
  return drizzle(client, { schema })
}

// An independent copy of `db` as it stands, ids and sequences included: two
// forks of one seeded database run the same turn to the same result, so two
// response paths can be compared on it.
export async function forkTestDb(db: TestDb): Promise<TestDb> {
  const dump = await db.$client.dumpDataDir('none')
  const client = await PGlite.create({ loadDataDir: dump, extensions: { vector } })
  onTestFinished(() => client.close())
  return drizzle(client, { schema })
}

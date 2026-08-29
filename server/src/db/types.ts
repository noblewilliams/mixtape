import type { PgDatabase, PgQueryResultHKT } from 'drizzle-orm/pg-core'
import type * as schema from './schema'

// Both the prod (neon-http) and test (pglite) drizzle instances are
// PgDatabase specializations; a neon-http/pglite ReturnType union caused
// query-builder overload resolution to collapse (e.g. .returning() on
// onConflictDoUpdate lost its argument), so this abstracts over the concrete
// query-result HKT instead of picking one driver's type.
export type Db = PgDatabase<PgQueryResultHKT, typeof schema>

import type { PgDatabase, PgQueryResultHKT } from 'drizzle-orm/pg-core'
import type * as schema from './schema'

// Both the prod (neon-serverless) and test (pglite) drizzle instances are
// PgDatabase specializations; a neon-serverless/pglite ReturnType union
// caused query-builder overload resolution to collapse (e.g. .returning() on
// onConflictDoUpdate lost its argument), so this abstracts over the concrete
// query-result HKT instead of picking one driver's type. neon-serverless
// replaced neon-http (Task 6 review): neon-http issues one HTTP fetch per
// query and can't run transactions at all — the queue store's
// SELECT ... FOR UPDATE needs a real session-scoped connection, which only
// neon-serverless's Pool (or neon-http's non-existent transaction support)
// could provide.
export type Db = PgDatabase<PgQueryResultHKT, typeof schema>

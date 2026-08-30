/**
 * retitle-sessions — one-off backfill: regenerate session titles via the
 * Haiku session-titling helper (dj/title.ts) for any session whose title is
 * still exactly the truncated-prompt fallback (routes/sessions.ts's
 * titleFromPrompt) — i.e. it predates this feature, or its own concurrent
 * title call at creation time failed/wasn't wired.
 *
 * Usage (from server/):  npx tsx scripts/retitle-sessions.ts [--dry-run]
 * Loads DATABASE_URL and ANTHROPIC_API_KEY from .dev.vars (same loading
 * style as scripts/dj-chat.ts) and calls the real Anthropic API — this is
 * NOT run automatically by anything; run it by hand after deploy.
 *
 * --dry-run prints every candidate's old → new title WITHOUT writing
 * anything to the database.
 */
import { readFileSync } from 'node:fs'
import { and, asc, eq } from 'drizzle-orm'
import { neon } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-http'
import * as schema from '../src/db/schema'
import { djSessions, djMessages } from '../src/db/schema'
import { buildAnthropic, anthropicComplete } from '../src/dj/llm'
import { generateSessionTitle } from '../src/dj/title'
import { titleFromPrompt } from '../src/routes/sessions'

function devVars(): Record<string, string> {
  const out: Record<string, string> = {}
  for (const line of readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8').split('\n')) {
    const i = line.indexOf('=')
    if (i > 0 && !line.startsWith('#')) out[line.slice(0, i)] = line.slice(i + 1).trim()
  }
  return out
}

async function main() {
  const dryRun = process.argv.includes('--dry-run')
  const env = devVars()
  if (!env.DATABASE_URL) throw new Error('DATABASE_URL missing from .dev.vars')
  if (!env.ANTHROPIC_API_KEY) throw new Error('ANTHROPIC_API_KEY missing from .dev.vars')

  const db = drizzle(neon(env.DATABASE_URL), { schema })
  const complete = anthropicComplete(buildAnthropic(env.ANTHROPIC_API_KEY))

  const sessions = await db.select().from(djSessions)
  console.log(`${sessions.length} session(s) total${dryRun ? ' — dry run, no writes' : ''}`)

  let candidates = 0
  let updated = 0

  for (const session of sessions) {
    // The first USER message by seq is always the session's opening prompt
    // (runDjTurn's persist-first contract inserts it before anything else),
    // so this is the exact text titleFromPrompt derived the fallback from.
    const [firstUserMessage] = await db
      .select({ content: djMessages.content })
      .from(djMessages)
      .where(and(eq(djMessages.sessionId, session.id), eq(djMessages.role, 'user')))
      .orderBy(asc(djMessages.seq))
      .limit(1)
    if (!firstUserMessage) continue // no messages at all — nothing to name from

    const expectedFallback = titleFromPrompt(firstUserMessage.content)
    if (session.title !== expectedFallback) continue // already renamed (generated or hand-edited) — leave it alone

    candidates += 1
    const newTitle = await generateSessionTitle(complete, firstUserMessage.content, expectedFallback)
    if (newTitle === expectedFallback) {
      console.log(`  [skip] ${session.id}: title call failed or returned nothing — left as "${expectedFallback}"`)
      continue
    }

    console.log(`  ${session.id}: "${session.title}" -> "${newTitle}"`)
    if (!dryRun) {
      await db.update(djSessions).set({ title: newTitle }).where(eq(djSessions.id, session.id))
      updated += 1
    }
  }

  console.log(dryRun ? `${candidates} candidate(s) would be updated` : `${candidates} candidate(s), ${updated} updated`)
}

main().catch((e) => {
  console.error('retitle-sessions failed:', e instanceof Error ? e.message : e)
  process.exit(1)
})

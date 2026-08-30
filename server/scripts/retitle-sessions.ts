/**
 * retitle-sessions — one-off backfill: regenerate session titles via the
 * Haiku session-titling helper (dj/title.ts) for any session whose title is
 * still exactly the truncated-prompt fallback (routes/sessions.ts's
 * titleFromPrompt) — i.e. it predates this feature, or its own concurrent
 * title call at creation time failed/wasn't wired.
 *
 * Usage (from server/):  npx tsx scripts/retitle-sessions.ts [--apply]
 * Loads DATABASE_URL and ANTHROPIC_API_KEY from .dev.vars (same loading
 * style as scripts/dj-chat.ts) and calls the real Anthropic API — this is
 * NOT run automatically by anything; run it by hand after deploy.
 *
 * Defaults to a DRY RUN: prints every candidate's old → new title WITHOUT
 * writing anything to the database. Pass --apply to actually write the
 * generated titles — this is a real-prod-DB write, so it's opt-in, not
 * opt-out.
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
    if (i > 0 && !line.startsWith('#')) {
      const key = line.slice(0, i)
      let value = line.slice(i + 1).trim()
      // Strip a single layer of matching surrounding quotes — a quoted
      // DATABASE_URL would otherwise reach neon() with the quote characters
      // still attached, which throws with the full connection string
      // (credentials included) embedded in the error message.
      if (
        value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))
      ) {
        value = value.slice(1, -1)
      }
      out[key] = value
    }
  }
  return out
}

async function main() {
  const apply = process.argv.includes('--apply')
  const env = devVars()
  if (!env.DATABASE_URL) throw new Error('DATABASE_URL missing from .dev.vars')
  if (!env.ANTHROPIC_API_KEY) throw new Error('ANTHROPIC_API_KEY missing from .dev.vars')

  // Never let a construction failure here bubble e.message up to main's own
  // catch — an unstripped/malformed DATABASE_URL makes neon() throw with the
  // full connection string (credentials included) embedded in its message.
  let db: ReturnType<typeof drizzle>
  try {
    db = drizzle(neon(env.DATABASE_URL), { schema })
  } catch {
    throw new Error('invalid DATABASE_URL in .dev.vars')
  }
  const complete = anthropicComplete(buildAnthropic(env.ANTHROPIC_API_KEY))

  const sessions = await db.select().from(djSessions)
  console.log(`${sessions.length} session(s) total${apply ? '' : ' — dry run, no writes'}`)

  let candidates = 0
  let updated = 0

  for (const session of sessions) {
    try {
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

      // Coupled to titleFromPrompt's CURRENT trim/cap/collapse order — if that
      // function's sanitize discipline ever changes, an old row's stored
      // fallback title can stop matching a freshly-recomputed one even though
      // nothing about the row itself changed, silently excluding it here.
      const expectedFallback = titleFromPrompt(firstUserMessage.content)
      if (session.title !== expectedFallback) continue // already renamed (generated or hand-edited) — leave it alone

      candidates += 1
      const newTitle = await generateSessionTitle(complete, firstUserMessage.content, expectedFallback)
      if (newTitle === expectedFallback) {
        console.log(`  [skip] ${session.id}: title call failed or returned nothing — left as "${expectedFallback}"`)
        continue
      }

      console.log(`  ${session.id}: "${session.title}" -> "${newTitle}"`)
      if (apply) {
        await db.update(djSessions).set({ title: newTitle }).where(eq(djSessions.id, session.id))
        updated += 1
      }
    } catch {
      // Fixed string only — never interpolate a DB error's own message,
      // which can carry connection details.
      console.log(`  failed: ${session.id}`)
    }
  }

  console.log(apply ? `${candidates} candidate(s), ${updated} updated` : `${candidates} candidate(s) would be updated`)
}

main().catch((e) => {
  console.error('retitle-sessions failed:', e instanceof Error ? e.message : e)
  process.exit(1)
})

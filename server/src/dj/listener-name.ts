import { eq } from 'drizzle-orm'
import { user } from '../db/schema'
import type { Db } from '../db/types'
import { firstName } from '../auth/profile-name'

// Profile name spec 2026-11-02: the mix and album DJs may use the listener's
// first name, sparingly. The name is listener-set data, so like memory notes
// it lands in the leading USER context message, never in `system`, and
// firstName has already run it through sanitizeForPrompt and capped it. The
// rule for using it is fixed text, so it lives in the static personas
// (FIRST_NAME_PERSONA_LINE), outside the listener-data block, and the persona
// strings still cache.
export const FIRST_NAME_PERSONA_LINE =
  "If the session context gives the listener's first name, use it rarely: at most once in a conversation, " +
  'never as a greeting.'

export async function loadFirstName(db: Db, userId: string): Promise<string | null> {
  const [row] = await db.select({ name: user.name }).from(user).where(eq(user.id, userId))
  return firstName(row?.name)
}

export function formatFirstNameLine(name: string | null): string | null {
  if (name === null) return null
  return `The listener's first name: ${name}.`
}

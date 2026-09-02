import { eq } from 'drizzle-orm'
import type { Db } from '../db/types'
import { djMemories } from '../db/schema'

// Hard cap on active notes per user — enforced at insert (here), at context
// load (dj/loop.ts's loadMemoryNotes) and by GET /me/memories, all from this
// one constant so the three can never quietly drift apart.
export const MAX_MEMORY_NOTES = 50

// A note's storage cap. contracts.ts's rememberPreferenceInputSchema bounds
// the model's tool input to the same 200 (pinned by test/dj/memory-notes),
// so a note the loop accepts is never clipped here; the interview truncates
// its answers to this before prefixing them.
export const MAX_MEMORY_NOTE_LENGTH = 200

export type MemoryNoteOutcome = 'saved' | 'duplicate' | 'capped' | 'empty'

// The one insert path for dj_memories, shared by the DJ's remember_preference
// tool and the interview: trim, cap the length, refuse past MAX_MEMORY_NOTES,
// and treat an exact duplicate as a no-op. Content-free outcomes only; a DB
// failure propagates so each caller can decide (the loop swallows it into a
// refusal, a route lets it 500).
export async function insertMemoryNote(db: Db, userId: string, rawNote: string): Promise<MemoryNoteOutcome> {
  const note = rawNote.trim().slice(0, MAX_MEMORY_NOTE_LENGTH).trim()
  if (note.length === 0) return 'empty'

  // The cap check and the insert below aren't atomic with each other, so
  // two concurrent saves for the same user can both pass this count and both
  // insert — under real concurrency the cap is advisory, not a hard
  // guarantee, and can be exceeded by a small margin. Acceptable at the
  // one-user-per-session request rates this app runs at.
  const existing = await db.select({ note: djMemories.note }).from(djMemories).where(eq(djMemories.userId, userId))
  if (existing.length >= MAX_MEMORY_NOTES) return 'capped'

  // onConflictDoNothing (backed by dj_memories' unique (user_id, note)
  // index) is the REAL dupe guard, unlike the cap check above — a plain
  // select-then-insert dupe check only ever sees its own read snapshot, so
  // two concurrent saves of the identical note could both pass a read
  // check and both insert. A conflict here returns no row.
  const [inserted] = await db
    .insert(djMemories)
    .values({ userId, note })
    .onConflictDoNothing({ target: [djMemories.userId, djMemories.note] })
    .returning({ id: djMemories.id })
  return inserted ? 'saved' : 'duplicate'
}

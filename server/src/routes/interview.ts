import { Hono } from 'hono'
import { zValidator } from '@hono/zod-validator'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import { funnelEvents } from '../db/schema'
import { insertMemoryNote, MAX_MEMORY_NOTE_LENGTH, type MemoryNoteOutcome } from '../dj/memory-notes'
import { replaceInterviewSeeds } from '../seeds/artist-seeds'
import { interviewSchema, type InterviewAnswers } from '../seeds/contracts'

// Fixed prefixes so the DJ (and the "What the DJ knows" screen) can tell an
// interview answer from a note it saved itself. The answer is cut so the
// whole note fits the note cap; the prefix is never what gets cut.
const NOTE_PREFIXES: ReadonlyArray<[prefix: string, pick: (answers: InterviewAnswers, artists: string[]) => string]> = [
  ['Never skips: ', (_answers, artists) => artists.join(', ')],
  ['Plays most: ', (answers) => answers.playsMost],
  ['Listens when: ', (answers) => answers.listensWhen],
  ['Never wants: ', (answers) => answers.neverWants],
  ['Era: ', (answers) => answers.era],
]

type NoteCounts = Record<Exclude<MemoryNoteOutcome, 'empty'>, number>

// Mounted at /me/interview, behind requireSession. The five-turn interview
// the waiting state runs before any mix (spec 2026-09-01 → Before the data
// arrives): named artists become interview seeds, every non-empty answer
// becomes a DJ memory through the same rules as remember_preference, and
// the funnel records interview_completed. One transaction, so a half-saved
// interview never exists.
export function interviewRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()

  app.post('/', zValidator('json', interviewSchema), async (c) => {
    const userId = c.get('user').id
    const answers = c.req.valid('json')
    const result = await db.transaction(async (tx) => {
      const artists = await replaceInterviewSeeds(tx, userId, answers.neverSkip)
      const notes: NoteCounts = { saved: 0, duplicate: 0, capped: 0 }
      for (const [prefix, pick] of NOTE_PREFIXES) {
        const answer = pick(answers, artists).trim()
        if (answer.length === 0) continue
        const outcome = await insertMemoryNote(tx, userId, prefix + answer.slice(0, MAX_MEMORY_NOTE_LENGTH - prefix.length))
        if (outcome !== 'empty') notes[outcome] += 1
      }
      await tx.insert(funnelEvents).values({ userId, type: 'interview_completed', surface: answers.surface })
      return { seeds: artists.length, notes }
    })
    return c.json(result)
  })

  return app
}

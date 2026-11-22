import type { Db } from '../../src/db/types'
import { insertUserMessage, runDjTurn as runDjTurnWithSeq, type DjDeps, type DjSessionRef, type DjTurnOptions, type DjTurnResult } from '../../src/dj/loop'

// runDjTurn as the routes call it: the listener's message inserted first
// (persist-first), then the turn, handed that row's seq. Tests that drive
// the loop directly use this so they read as they did when runDjTurn did
// the insert itself.
export async function runDjTurn(
  db: Db,
  deps: DjDeps,
  session: DjSessionRef,
  userText: string,
  options: Omit<DjTurnOptions, 'userMessageSeq'> = {},
): Promise<DjTurnResult> {
  const userMessageSeq = await insertUserMessage(db, session.id, userText)
  return runDjTurnWithSeq(db, deps, session, userText, { ...options, userMessageSeq })
}

import type { Session, User } from 'better-auth'

// Better Auth's anonymous plugin calls this after a social sign-in that
// arrives with an anonymous session, before it deletes the anonymous user.
// Task 3 of the first-run plan fills in the merge (repointing the anonymous
// listener's rows to the signed-in account); until then it is a no-op and the
// plugin's cascade delete removes everything the anonymous user owned.
export type LinkAnonymousAccountInput = {
  anonymousUser: { user: User & Record<string, unknown>; session: Session & Record<string, unknown> }
  newUser: { user: User & Record<string, unknown>; session: Session & Record<string, unknown> }
}

export async function linkAnonymousAccount(_input: LinkAnonymousAccountInput): Promise<void> {}

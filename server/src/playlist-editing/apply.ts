import { and, asc, eq } from 'drizzle-orm'
import type { Db } from '../db/types'
import {
  playlistEditDraftEntries,
  playlistEditDraftEvents,
  playlistEditDrafts,
  playlistOrigins,
  userPlaylists,
} from '../db/schema'

const PLAN_TTL_MS = 10 * 60 * 1_000
const REVISION_SUFFIX = ' (mixtape revision)'

export type RevisedCopyPlan = {
  operationId: string
  mode: 'revised_copy'
  draftVersion: number
  expiresAt: Date
  name: string
  description: 'revised with mixtape'
  appleCatalogIds: string[]
  desiredFingerprint: string
  sourceWillRemainUntouched: true
}

type PrepareResult =
  | { kind: 'ok'; plan: RevisedCopyPlan }
  | { kind: 'not_found' }
  | { kind: 'version_conflict' }
  | { kind: 'source_conflict' }
  | { kind: 'blocked'; unresolved: number }
  | { kind: 'no_changes' }
  | { kind: 'unsupported_client' }
  | { kind: 'terminal' }

export type ApplyConfirmation = {
  operationId: string
  expectedVersion: number
  appliedMode: 'revised_copy'
  applePlaylistLibraryId: string
  resultingFingerprint: string
}

export type ConfirmedApply = {
  draftId: string
  status: 'applied'
  mode: 'revised_copy'
  applePlaylistLibraryId: string
  resultingFingerprint: string
  sourceWillRemainUntouched: true
}

type ConfirmResult =
  | { kind: 'ok'; confirmation: ConfirmedApply }
  | { kind: 'not_found' }
  | { kind: 'version_conflict' }
  | { kind: 'plan_mismatch' }
  | { kind: 'result_mismatch' }
  | { kind: 'terminal' }

function hex(bytes: ArrayBuffer): string {
  return [...new Uint8Array(bytes)].map((value) => value.toString(16).padStart(2, '0')).join('')
}

export async function desiredPlaylistFingerprint(appleCatalogIds: string[]): Promise<string> {
  const canonical = `mixtape-playlist-apply-v1\n${appleCatalogIds.length}\n${appleCatalogIds.join('\n')}`
  return hex(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(canonical)))
}

function revisedName(baseName: string): string {
  return `${baseName.slice(0, 500 - REVISION_SUFFIX.length)}${REVISION_SUFFIX}`
}

function sameSnapshot(
  base: Array<typeof playlistEditDraftEntries.$inferSelect>,
  draft: Array<typeof playlistEditDraftEntries.$inferSelect>,
): boolean {
  return base.length === draft.length && base.every((entry, position) => {
    const other = draft[position]
    return other != null
      && entry.entryKey === other.entryKey
      && entry.trackId === other.trackId
      && entry.appleLibraryTrackId === other.appleLibraryTrackId
      && entry.appleCatalogId === other.appleCatalogId
      && entry.spotifyId === other.spotifyId
  })
}

function confirmationFor(
  draftId: string,
  libraryId: string,
  fingerprint: string,
): ConfirmedApply {
  return {
    draftId,
    status: 'applied',
    mode: 'revised_copy',
    applePlaylistLibraryId: libraryId,
    resultingFingerprint: fingerprint,
    sourceWillRemainUntouched: true,
  }
}

export function createPlaylistApplyStore(
  db: Db,
  options: { now?: () => Date } = {},
) {
  const now = options.now ?? (() => new Date())
  return {
    async prepare(
      userId: string,
      draftId: string,
      expectedVersion: number,
      currentSourceFingerprint: string,
      revisedCopySupported: boolean,
    ): Promise<PrepareResult> {
      return db.transaction(async (tx) => {
        const [draft] = await tx.select().from(playlistEditDrafts).where(and(
          eq(playlistEditDrafts.id, draftId),
          eq(playlistEditDrafts.userId, userId),
        )).limit(1).for('update')
        if (!draft) return { kind: 'not_found' as const }
        if (draft.version !== expectedVersion) return { kind: 'version_conflict' as const }
        if (!revisedCopySupported) return { kind: 'unsupported_client' as const }
        if (draft.status === 'conflicted') return { kind: 'source_conflict' as const }
        if (draft.status !== 'active' && draft.status !== 'ready') {
          return { kind: 'terminal' as const }
        }

        const [source] = await tx.select({
          fingerprint: userPlaylists.sourceFingerprint,
          inLibrary: userPlaylists.inLibrary,
        }).from(userPlaylists).where(and(
          eq(userPlaylists.id, draft.sourcePlaylistId),
          eq(userPlaylists.userId, userId),
        )).limit(1).for('share')
        if (
          !source
          || !source.inLibrary
          || source.fingerprint !== draft.baseSourceFingerprint
          || currentSourceFingerprint !== draft.baseSourceFingerprint
        ) {
          await tx.update(playlistEditDrafts).set({
            status: 'conflicted',
            updatedAt: now(),
          }).where(eq(playlistEditDrafts.id, draft.id))
          return { kind: 'source_conflict' as const }
        }

        const entries = await tx.select().from(playlistEditDraftEntries).where(
          eq(playlistEditDraftEntries.draftId, draft.id),
        ).orderBy(asc(playlistEditDraftEntries.role), asc(playlistEditDraftEntries.position))
        const base = entries.filter((entry) => entry.role === 'base')
        const desired = entries.filter((entry) => entry.role === 'draft')
        if (sameSnapshot(base, desired)) return { kind: 'no_changes' as const }
        const unresolved = desired.filter((entry) => entry.appleCatalogId == null).length
        if (unresolved > 0) return { kind: 'blocked' as const, unresolved }

        const appleCatalogIds = desired.map((entry) => entry.appleCatalogId!)
        const desiredFingerprint = await desiredPlaylistFingerprint(appleCatalogIds)
        const currentTime = now()
        if (
          draft.status === 'ready'
          && draft.requestedApplyMode === 'revised_copy'
          && draft.preparedOperationId != null
          && draft.preparedExpiresAt != null
          && draft.preparedDesiredFingerprint === desiredFingerprint
        ) {
          const expiresAt = draft.preparedExpiresAt > currentTime
            ? draft.preparedExpiresAt
            : new Date(currentTime.getTime() + PLAN_TTL_MS)
          if (expiresAt !== draft.preparedExpiresAt) {
            await tx.update(playlistEditDrafts).set({
              preparedExpiresAt: expiresAt,
              updatedAt: currentTime,
            }).where(eq(playlistEditDrafts.id, draft.id))
          }
          return {
            kind: 'ok' as const,
            plan: {
              operationId: draft.preparedOperationId,
              mode: 'revised_copy',
              draftVersion: draft.version,
              expiresAt,
              name: revisedName(draft.baseName),
              description: 'revised with mixtape',
              appleCatalogIds,
              desiredFingerprint,
              sourceWillRemainUntouched: true,
            },
          }
        }

        const operationId = crypto.randomUUID()
        const expiresAt = new Date(currentTime.getTime() + PLAN_TTL_MS)
        await tx.update(playlistEditDrafts).set({
          status: 'ready',
          requestedApplyMode: 'revised_copy',
          preparedOperationId: operationId,
          preparedExpiresAt: expiresAt,
          preparedDesiredFingerprint: desiredFingerprint,
          updatedAt: currentTime,
        }).where(eq(playlistEditDrafts.id, draft.id))
        return {
          kind: 'ok' as const,
          plan: {
            operationId,
            mode: 'revised_copy',
            draftVersion: draft.version,
            expiresAt,
            name: revisedName(draft.baseName),
            description: 'revised with mixtape',
            appleCatalogIds,
            desiredFingerprint,
            sourceWillRemainUntouched: true,
          },
        }
      })
    },

    async confirm(
      userId: string,
      draftId: string,
      input: ApplyConfirmation,
    ): Promise<ConfirmResult> {
      return db.transaction(async (tx) => {
        const [draft] = await tx.select().from(playlistEditDrafts).where(and(
          eq(playlistEditDrafts.id, draftId),
          eq(playlistEditDrafts.userId, userId),
        )).limit(1).for('update')
        if (!draft) return { kind: 'not_found' as const }
        if (draft.version !== input.expectedVersion) {
          return { kind: 'version_conflict' as const }
        }
        const exactPlan = draft.requestedApplyMode === input.appliedMode
          && draft.preparedOperationId === input.operationId
          && draft.preparedDesiredFingerprint === input.resultingFingerprint
        if (draft.status === 'applied') {
          if (
            exactPlan
            && draft.appliedPlaylistLibraryId === input.applePlaylistLibraryId
          ) {
            return {
              kind: 'ok' as const,
              confirmation: confirmationFor(
                draft.id,
                input.applePlaylistLibraryId,
                input.resultingFingerprint,
              ),
            }
          }
          return { kind: 'terminal' as const }
        }
        if (draft.status !== 'ready' || !exactPlan) {
          return draft.preparedOperationId === input.operationId
            ? { kind: 'result_mismatch' as const }
            : { kind: 'plan_mismatch' as const }
        }

        await tx.insert(playlistOrigins).values({
          userId,
          source: 'apple',
          libraryId: input.applePlaylistLibraryId,
          origin: 'mixtape',
        }).onConflictDoUpdate({
          target: [playlistOrigins.userId, playlistOrigins.source, playlistOrigins.libraryId],
          set: { origin: 'mixtape' },
        })
        await tx.insert(playlistEditDraftEvents).values({
          draftId: draft.id,
          version: draft.version,
          kind: 'apply',
        })
        const appliedAt = now()
        await tx.update(playlistEditDrafts).set({
          status: 'applied',
          appliedPlaylistSource: 'apple',
          appliedPlaylistLibraryId: input.applePlaylistLibraryId,
          appliedAt,
          updatedAt: appliedAt,
        }).where(eq(playlistEditDrafts.id, draft.id))
        return {
          kind: 'ok' as const,
          confirmation: confirmationFor(
            draft.id,
            input.applePlaylistLibraryId,
            input.resultingFingerprint,
          ),
        }
      })
    },
  }
}

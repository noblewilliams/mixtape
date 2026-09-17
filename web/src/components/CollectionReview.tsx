import {
  applySelection,
  type CollectionSelection,
  type FileSelection,
} from '../import/collection-review'
import type {
  ExportInventory,
  ListeningExportSnapshot,
} from '../import/snapshot'
export function CollectionReview({
  inventory,
  snapshot,
  selection,
  onChange,
}: {
  inventory: ExportInventory
  snapshot: ListeningExportSnapshot
  selection: CollectionSelection
  onChange: (s: CollectionSelection) => void
}) {
  const update = (i: number, change: Partial<FileSelection>) =>
    onChange({
      ...selection,
      confirmed: false,
      confirmRemovals: false,
      files: selection.files.map((f, j) => (j === i ? { ...f, ...change } : f)),
    })
  const liked = selection.files.find((f) => f.role === 'liked')
  const incoming = new Set(
    snapshot.package === 'spotify_account'
      ? snapshot.library.map((r) => r.platformId)
      : (snapshot.playlists
          .find((p) => p.ordinal === liked?.ordinal)
          ?.entries.flatMap((e) => (e.platformId ? [e.platformId] : [])) ?? []),
  )
  let summary: ReturnType<typeof applySelection> | null = null
  try {
    summary = applySelection(snapshot, {
      ...selection,
      confirmed: true,
      confirmRemovals: true,
    })
  } catch {
    /* Invalid roles keep upload disabled. */
  }
  const removals = selection.context.library.ids.filter(
    (id) => !incoming.has(id),
  ).length
  return (
    <div className="collection-review">
      <h2>Review your music</h2>
      {summary ? (
        <p className="review-counts">
          {summary.snapshot.tracks.length} unique songs ·{' '}
          {summary.snapshot.library.length} liked songs ·{' '}
          {summary.snapshot.playlists.length} playlists ·{' '}
          {summary.snapshot.playlists.reduce((n, p) => n + p.entries.length, 0)}{' '}
          playlist entries
        </p>
      ) : (
        <p role="status">
          Choose at least one nonempty collection, valid names, distinct
          replacement targets, and no more than one Liked Songs file.
        </p>
      )}
      <p className="note">
        Files suggest names, not playlist identities. Choose what each file
        represents. Other playlists and listening history stay as they are.
      </p>
      {selection.files.map((file, i) => (
        <fieldset key={file.ordinal} className="collection-file">
          <legend>
            {inventory.read[i]?.path ?? snapshot.playlists[i]?.name} ·{' '}
            {snapshot.playlists[i]?.entries.length ?? 0} entries
          </legend>
          {file.name.toLowerCase() === 'liked' ? (
            <p className="note">
              This may be Liked Songs. Confirm its role below.
            </p>
          ) : null}
          <div className="collection-fields">
            <label>
              Save as
              <input
                maxLength={500}
                value={file.name}
                disabled={file.role !== 'playlist'}
                onChange={(e) => update(i, { name: e.target.value })}
              />
            </label>
            <label>
              Use as
              <select
                value={file.role}
                onChange={(e) =>
                  update(i, { role: e.target.value as FileSelection['role'] })
                }
              >
                <option value="playlist">Playlist</option>
                <option value="liked">Liked Songs</option>
                <option value="skip">Skip</option>
              </select>
            </label>
            {file.role === 'playlist' ? (
              <label>
                Playlist action
                <select
                  value={file.target ?? ''}
                  onChange={(e) =>
                    update(i, {
                      target: e.target.value || null,
                      ...(!e.target.value
                        ? { createKey: `exportify:new:${crypto.randomUUID()}` }
                        : {}),
                    })
                  }
                >
                  <option value="">Create new playlist</option>
                  {selection.context.playlists.map((p) => (
                    <option key={p.key} value={p.key}>
                      Replace: {p.name}
                    </option>
                  ))}
                </select>
              </label>
            ) : null}
          </div>
        </fieldset>
      ))}
      {liked || snapshot.package === 'spotify_account' ? (
        <div className="collection-file">
          <label>
            Liked Songs update
            <select
              value={selection.libraryMode}
              onChange={(e) =>
                onChange({
                  ...selection,
                  libraryMode: e.target.value as 'add' | 'replace',
                  confirmed: false,
                  confirmRemovals: false,
                })
              }
            >
              <option value="add">Add songs</option>
              <option value="replace">Replace imported Liked Songs</option>
            </select>
          </label>
          {selection.libraryMode === 'replace' ? (
            <label className="collection-confirm">
              <input
                type="checkbox"
                checked={selection.confirmRemovals}
                onChange={(e) =>
                  onChange({ ...selection, confirmRemovals: e.target.checked })
                }
              />
              Replace Spotify imported Liked Songs, removing {removals}{' '}
              previously imported songs from this saved collection. Other
              providers stay unchanged.
            </label>
          ) : null}
        </div>
      ) : null}
      <label className="collection-confirm">
        <input
          type="checkbox"
          checked={selection.confirmed}
          onChange={(e) =>
            onChange({ ...selection, confirmed: e.target.checked })
          }
        />
        I reviewed the collection roles and replacement targets.
      </label>
      <p className="note">
        This export contains saved music, not listening history. Add history
        later with Go deeper.
      </p>
    </div>
  )
}
export function selectionCanUpload(
  snapshot: ListeningExportSnapshot,
  selection?: CollectionSelection,
): boolean {
  if (!selection) return snapshot.package !== 'spotify_exportify'
  try {
    applySelection(snapshot, selection)
    return true
  } catch {
    return false
  }
}

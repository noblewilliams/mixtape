// The door on a catalog mix (approval
// docs/mockups/approved/2026-11-09-add-your-music-loop.md; board section 5,
// frames W1 to W3). One quiet line and one action under the last DJ turn of
// a mix the DJ made from Mixtape's catalog (the session's `notPersonal`),
// and, in the phone shell, in the mix panel's banner. It is the honest label
// for a catalog mix, so it has no dismiss, and it follows the run it starts:
// syncing, failed, Spotify's export waiting, and music in.
import { useId, useState, useSyncExternalStore, type ReactNode } from 'react'
import type { OnboardingResponse } from '../api/client'
import type { AddMusicPlatform, AddMusicTarget } from '../lib/add-music-route'
import { spotifyExportWaiting } from '../lib/onboarding'
import type { MusicSyncRun, MusicSyncRunState } from '../sync/music-sync-run'
import type { MusicSyncProgress } from '../sync/music-sync-service'
import { FileIcon, SyncIcon } from './Icons'
import { AppleMusicMark, SpotifyMark } from './ProviderMarks'
import './music-door.css'

/** What the door says, in the contract's priority order. */
export type MusicDoorState = 'remade' | 'musicIn' | 'syncing' | 'syncFailed' | 'spotifyWaiting' | 'noMusic'

export const CATALOG_LINE = 'From Mixtape’s catalog for now. With your music, the DJ picks from what you actually play.'
const SHORT_LINE = 'From Mixtape’s catalog for now.'
const BANNER_TITLE = 'Not personal yet'
const SYNCING_LEAD = 'Syncing Apple Music…'
const SYNCING_TAIL = 'You can keep chatting while it runs.'
const FAILED_LINE = 'Sync didn’t finish.'
const WAITING_LINE = 'Waiting on your Spotify data. It can take a few days.'
const MUSIC_IN_LEAD = 'Your music is in.'
const MUSIC_IN_TAIL = 'This mix was made before it.'
const REMAKE_LABEL = 'Remake with my music'
const REMAKE_HINT = 'Makes a new version from your music.'
const PLATFORM_ACTION: Record<'apple' | 'spotify' | 'none', string> = {
  apple: 'Sync Apple Music',
  spotify: 'Add Spotify music',
  none: 'Add your music',
}
// The whole run as one bar, stage by stage in the order the sync goes: each
// stage owns a slice, filled by its own count when its total is known. Reading
// the library and uploading its songs are the long parts.
const STAGE_SLICES: Record<MusicSyncProgress['stage'], [number, number]> = {
  authorizing: [0, 0],
  library_songs: [0, 40],
  playlists: [40, 44],
  playlist_tracks: [44, 48],
  recent_tracks: [48, 50],
  uploading_library: [50, 80],
  saving_library: [80, 80],
  uploading_playlists: [80, 96],
  saving_playlists: [96, 96],
  complete: [100, 100],
}

type StateInput = {
  notPersonal: boolean
  onboarding: OnboardingResponse | null
  sync: MusicSyncRunState
  /** A published sync's onboarding read is in flight: the run has not landed for the door yet. */
  syncLanding?: boolean
  /** Where this listener plays: a Spotify device is never told an Apple sync failed (as on iOS). */
  platform: AddMusicPlatform
}

export function musicDoorState({ notPersonal, onboarding, sync, syncLanding = false, platform }: StateInput): MusicDoorState {
  if (!notPersonal) return 'remade'
  if (onboarding?.musicReady) return 'musicIn'
  if (sync.kind === 'running' || sync.kind === 'cancelling' || syncLanding) return 'syncing'
  if (platform !== 'spotify' && syncFailed(sync)) return 'syncFailed'
  if (spotifyExportWaiting(onboarding)) return 'spotifyWaiting'
  return 'noMusic'
}

/**
 * The last sync this page load did not finish. A refused or cancelled
 * authorisation is not a failure: the door goes back to its first state.
 */
function syncFailed(sync: MusicSyncRunState): boolean {
  if (sync.kind === 'error') return sync.failure !== 'permission'
  return sync.kind === 'result' && sync.result.kind !== 'complete'
}

/**
 * The whole sync's progress, 0 to 100: the stage's slice, filled by its count
 * when its total is known. Null when no sync runs; full while a published
 * sync's onboarding read lands.
 */
export function syncProgress(sync: MusicSyncRunState, landing = false): number | null {
  if (sync.kind !== 'running' && sync.kind !== 'cancelling') return landing ? 100 : null
  if (!sync.progress) return 0
  const { stage, completed, total } = sync.progress
  const [start, end] = STAGE_SLICES[stage]
  const share = total && total > 0 ? Math.min(1, Math.max(0, completed / total)) : 0
  return start + (end - start) * share
}

/** What App hands the door: the same for the conversation's line and the phone shell's banner. */
export type MusicDoorInput = {
  onboarding: OnboardingResponse | null
  syncRun: Pick<MusicSyncRun, 'getState' | 'subscribe'>
  syncLanding?: boolean
  /** Where this listener plays, as the add-music router reads it. */
  platform: AddMusicPlatform
  onAddMusic: (target: AddMusicTarget) => void
  onRemake: () => void
  /** A turn is in flight (or the mix is still opening): Remake waits. */
  busy?: boolean
  /**
   * A remake is on its way: from the tap until its reads land, the door steps
   * aside (mounted, hidden), so it is neither re-enabled nor read out meanwhile.
   */
  pending?: boolean
}

type MusicDoorProps = MusicDoorInput & {
  notPersonal: boolean
  /** `line`: under the last DJ turn. `banner`: the phone shell's mix panel banner, label first. */
  layout?: 'line' | 'banner'
}

export function MusicDoor({ notPersonal, layout = 'line', onboarding, syncRun, syncLanding, platform, onAddMusic, onRemake, busy = false, pending = false }: MusicDoorProps) {
  const sync = useSyncExternalStore(syncRun.subscribe, syncRun.getState)
  const hintId = useId()
  const state = musicDoorState({ notPersonal, onboarding, sync, syncLanding, platform })
  // The bar only moves forward within a run: the highest progress seen holds
  // until the door stops syncing (derived state, set while rendering).
  const progress = state === 'syncing' ? syncProgress(sync, syncLanding) : null
  const [peak, setPeak] = useState(0)
  if (progress === null && peak !== 0) setPeak(0)
  else if (progress !== null && progress > peak) setPeak(progress)
  if (state === 'remade') return null

  const shown = progress === null ? null : Math.floor(Math.max(progress, peak))
  const percent = shown ? shown : null
  // The live region keeps stable words: the moving percent is drawn but hidden
  // from it, so a sync is announced at its start and end, never per percent.
  const line: ReactNode =
    state === 'syncing' ? (
      <>
        <strong>{SYNCING_LEAD}</strong>
        {percent !== null ? <strong aria-hidden="true">{` ${percent}%.`}</strong> : null}
        {` ${SYNCING_TAIL}`}
      </>
    ) : state === 'musicIn' ? (
      <>
        <strong>{MUSIC_IN_LEAD}</strong>
        {` ${MUSIC_IN_TAIL}`}
      </>
    ) : state === 'syncFailed' ? FAILED_LINE
    : state === 'spotifyWaiting' ? WAITING_LINE
    : CATALOG_LINE

  const pill = (label: string, glyph: ReactNode, target: AddMusicTarget) => (
    <button type="button" className="music-door-pill" onClick={() => onAddMusic(target)}>
      {glyph}
      {label}
    </button>
  )
  const action: ReactNode =
    state === 'noMusic' ? pill(
      PLATFORM_ACTION[platform ?? 'none'],
      platform === 'apple' ? <AppleMusicMark /> : platform === 'spotify' ? <SpotifyMark /> : null,
      'door',
    )
    : state === 'syncFailed' ? pill('Try again', <SyncIcon />, 'retrySync')
    : state === 'spotifyWaiting' ? pill('Choose files', <FileIcon />, 'door')
    : state === 'musicIn' ? (
      <>
        {/* The web's primary action shape, as the album panel's Play. */}
        <button type="button" className="album-play music-door-remake" disabled={busy} aria-describedby={hintId} onClick={onRemake}>
          {REMAKE_LABEL}
        </button>
        <span id={hintId} hidden>{REMAKE_HINT}</span>
      </>
    )
    : (
      <div className="music-door-bar" aria-hidden="true">
        <i style={{ width: `${shown ?? 0}%` }} />
      </div>
    )

  const tone = state === 'syncFailed' ? ' music-door--err' : ''
  if (layout === 'banner') {
    return (
      <div className={`banner banner--door${tone}`} role="status" hidden={pending}>
        <span aria-hidden="true">◐</span>
        <div className="banner-door-copy">
          <b>{BANNER_TITLE}</b>
          <p className="music-door-line">{line}</p>
        </div>
        <div className="banner-door-act">{action}</div>
      </div>
    )
  }
  return (
    <div className={`music-door${tone}`} role="status" hidden={pending}>
      <p className="music-door-line">{line}</p>
      {action}
    </div>
  )
}

/** The desktop banner: the label and the short line, with no action (the conversation carries it). */
export function CatalogBanner() {
  return (
    <div className="banner" role="status">
      <span aria-hidden="true">◐</span>
      <span>
        <b>{BANNER_TITLE}</b>
        <span>{SHORT_LINE}</span>
      </span>
    </div>
  )
}

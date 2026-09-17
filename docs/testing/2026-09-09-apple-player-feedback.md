# Apple player and observed listening — local implementation

Web extends the existing MusicKit JS player. Native adds ApplicationMusicPlayer
behind a separate Flutter method/event channel; the existing system-player handoff
and playlist creation path remain intact. In the native mix, Play in Mixtape opens
the new player; Send to Music keeps the handoff. The mini-player is available in
Home/chat. Playback takes a copy of the selected tracks and mix version. Later mix
edits/restores do not silently replace it. The web Play action distinguishes the
currently playing version from a revised version.

Controls: pause/resume, previous/next, repeat song, seek on release, stop/cancel,
explicit Apple authorization/reconnection, and native Send to Music. Provider errors
preserve the mix. Cancellation fences late queue preparation and authorization.
Failed starts retry the intended queue, never an older queue left in the provider.
MusicKit state and queue notifications drive native snapshots; MusicKit JS events
plus a one-second sampling fallback drive web snapshots. Native SDK calls compiled
against the installed iOS 26.5 SDK. Web getters and state constants were checked
against Apple's public v3 bundle: playing=2, paused=3, stopped=4, ended=5.

## Learning contract

Learning starts off and requires an explicit switch in Listening preferences.
Evidence is account-scoped, separate from imported history, manual DJ preferences,
and the existing playlist/mix actions. It does not increment imported play counts.

The meter compares consecutive monotonic timestamps and actual playback progress.
Credit requires playing on both observations, a gap no larger than 2.5 seconds,
and progress within 750 ms of elapsed time. It credits the smaller of progress and
elapsed time. Pauses, stalled progress, seeks and unobserved gaps add no time.
Background callbacks may contribute when continuous observations are available;
missing background intervals are never filled in. Only explicit app Next/Repeat
commands create those intent signals. External/unknown transitions are not dislikes.

A listen needs min(60 seconds, 80% of duration), with a 10-second floor. Early skips
need at least 3 seconds and less than min(30 seconds, 25% of duration). Repeats need
30 observed seconds. Next after a substantial listen is a listen, not a penalty.
The server validates these thresholds against track duration and checks ownership,
recording identity and position in the immutable played mix version.

One occurrence ID (playback UUID + sequence) is idempotent across retries. Outboxes
hold at most 100 observations, restore only the current account/consent revision,
expire restored items after seven days, and send batches of at most 20. Failed
uploads retry at 30-second intervals while the controller is alive. Web uses
account-keyed local storage; native uses account-keyed secure storage with serialized
writes/deletion. Sign-out and local opt-out discard pending evidence. Consent and
clear revisions reject stale device uploads; clear requests also check their expected
revision and retain an idempotency ID for unknown-response reconciliation.

Scoring groups evidence by artist and UTC day over 90 days. A single skip has no
negative effect; at least two negative days are required. Positive evidence wins
within a day. This separate contribution is capped at +/-0.03 and never overrides
candidate eligibility or exclusions. Switching learning off removes its influence
immediately. Clear deletes the evidence; derived scoring is computed from remaining
rows, so there is no stale aggregate to repair. Existing imports/mixes/written
preferences remain. Old rows are cleaned opportunistically on ingest; the 90-day
window is a scoring horizon, not a promise of scheduled deletion. Ingest is capped
at 500 accepted-row budget per account per rolling day. Account deletion cascades.

## Verification

- Full server: 84 files passed / 1 skipped; 1,343 tests passed / 1 skipped.
- Full web: 48 files passed / 1 skipped; 383 tests passed / 1 skipped.
- Later focused checks cover SDK end states, invalid time, cancelled preparation,
  fixed-version attribution, failed-start recovery, authorization cancellation,
  offline retry identity, seek on release and clear confirmation.
- Native existing Home/chat/queue plus new meter/controller: 100 tests passed.
  Final focused controller/player checks additionally cover failed-start recovery
  and 320×568 at 200% text. Native analysis is scoped to changed production paths.
- Web production build and unsigned native iOS build succeeded. Existing bundle-size,
  Pods deployment-target and Flutter AppDelegate migration advisories remain.
- Actual UI components reviewed in the browser at /qa/player.html and through the
  native rendered image /tmp/mixtape-energy-screens/player-native-dark.png. Harness
  audio/state is synthetic; this is visual verification, not provider playback.

## Release and physical-device acceptance still open

Source is local. Migration 0031 follows pending 0029/0030; deploy matching API/web and
rebuild/install the native app together. Do not deploy the shared dirty checkout.
The existing account/import/mix/play/save flows were already founder-tested; the
remaining acceptance below concerns the new app-owned player/observations only.

On a subscribed Apple account, verify exact song order and version, pause/resume,
seek, repeat, last-song completion and changing the mix while an older version plays.
Then verify a call, headphones disconnect, lock-screen commands, background/resume,
unavailable songs, denied/revoked authorization and cancellation during preparation.
Confirm that missed intervals add no evidence and interruptions create no skip.
Test offline collection/reconnection once, then off/clear from another device before
reconnect; stale evidence must not return. Verify sign-out stops the owned player and
discards unsent evidence. Compare learning on/off while imported counts and written
preferences stay fixed. No physical-device or live auditory acceptance is claimed
from mocks or a successful build.

References: [Apple MusicPlayer](https://developer.apple.com/documentation/musickit/musicplayer),
[playback state](https://developer.apple.com/documentation/musickit/musicplayer/state-swift.class),
[playback time](https://developer.apple.com/documentation/musickit/musicplayer/playbacktime),
and [Apple MusicKit JS v3](https://js-cdn.music.apple.com/musickit/v3/musickit.js).

# Approved one platform, fixed mix actions

Approved November 9, 2026: the founder replied "Approve, build it" to the
[board](../2026-11-09-one-platform-play.html). Spec:
`docs/superpowers/specs/2026-11-09-one-platform-play-design.md`.

Supersedes, from the [3 November approval](2026-11-03-mix-conversation-redesign.md),
split Play (winner B) and its "Choose where to play" popover. Also supersedes
the "Play on Spotify" label from `docs/decisions.md` 2026-11-03 and 2026-11-06.
Everything else in those records stands.

## Winning variants and rejected alternatives

- **Strip layout A won**: the actions sit on their own row under the mix
  title. **B**, inline with an icon-only playlist button, lost because an
  unlabeled action is the ambiguity the TestFlight recording showed.
- Split Play was dropped. One platform per device decides the bar.

## Locked behaviour

- **Platform.** Each device has one platform: Apple Music or Spotify.
  - Stored `here` and `apple_music` both read as Apple Music.
  - A known service (`chosenService` apple/spotify, or a live Apple library)
    is written silently as the platform.
- **Ask once.** The "Where do you listen?" sheet opens over the shell the
  first time it appears after first run, and only when the platform is
  unknown.
  - Two equal pills, Apple Music first, each with its mark.
  - No grab handle, and neither the scrim nor a drag closes it.
  - Copy: "Your mixes play or save there. You can change it any time in You."
  - The first-Play ask is removed.
- **Apple Music bar.** Play plus Create playlist (the Apple playlist), with
  no arrow.
  - Play reads Playing, with the prism meter, while Mixtape's player is on
    this mix, and opens Now Playing.
  - Nothing else on the bar changes state.
- **Spotify bar.** One full-width tape button, "Create playlist" with the
  Spotify mark. It runs the TuneMyMusic handoff. Its accessible name is
  "Create Spotify playlist".
  - There is no Play.
  - Rows open in Spotify, as a search when there is no Spotify id.
  - The first-handoff explainer is unchanged.
- **Same actions in both places.** The strip on the conversation and the
  sticky bar on the tape show the same actions. In the strip they sit on a
  row under the title. At accessibility text sizes they stack full width.
- **Play outcomes (Apple Music).** Each case ends in music or a reason:
  - Access never asked: the iOS prompt appears on the tap.
  - The app player fails: the mix goes to the Music app with the existing
    "Playing in Apple Music" toast, including the skipped count.
  - Only a missing subscription, when the Music app fails as well, gives the
    toast "Playing needs an Apple Music subscription."
  - Any other start where the Music app fails as well gives "Apple Music
    couldn't play this mix." It never shows Apple's raw error text. Added
    after the simulator check on 9 November, which showed
    `MPMusicPlayerControllerErrorDomain` text in the toast.
- **You → Listen on.** Two choices, Apple Music and Spotify, shown in an
  anchored popover with a tick on the current one.
- The existing reason line, shown when nothing in the mix matches Apple
  Music, stays.

## Out of scope

- Web rail parity: a follow-up.

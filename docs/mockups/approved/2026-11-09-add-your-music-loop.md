# Approved: add your music, label, link, remake

Approved November 9, 2026: the founder replied "Approve, plan it" to the
[board](../2026-11-09-add-your-music-loop.html). Spec:
`docs/superpowers/specs/2026-11-09-add-your-music-loop-design.md`.

Supersedes the copy of the "Not personal yet" explanation everywhere it
shows ("Built from Mixtape's catalog and your interview, not your listening.
Import your Spotify data for the real thing.") and the text-only rule for
the tape block ("text only, since Home is the only screen that pushes the
import"). The 3 November conversation approval and the 9 November
one-platform approval stand.

## Winning variants and rejected alternatives

- **Remake as a small tape button (3A) won.** It uses the app's
  primary-action shape, because the remake is the moment the label
  promised.
  - Lost: a plain IdeaPill (3B), which read as one more suggestion.
- **One action per catalog mix.** A separate DJ pill on catalog mixes was
  dropped, because the line already carries the action. The only DJ pill is
  "Add my listening history", for listeners with music but no plays.
- **No dismiss on the line.** It is the honest label for a catalog mix, not
  a pitch.
- **Web: one action per visible screen.** On desktop the action is in the
  conversation, and the panel banner shows the label only. In the phone
  shell the banner carries the action.

## Locked behaviour

- **The line.** It sits under the last turn of a catalog mix (the session's
  `notPersonal`) and on the tape screen's flush block. It is one line, then
  one action. It has no box, and on the tape a hairline sits under it.
  - Copy: "From Mixtape's catalog for now. With your music, the DJ picks
    from what you actually play."
  - The header subtitle "Not personal yet" stays as the label and is not
    tappable.
- **The action** is an IdeaPill named for the device platform:
  - Apple Music: Apple Music mark, "Sync Apple Music".
  - Spotify: Spotify mark, "Add Spotify music".
  - Unknown: "Add your music", with no mark.
- **Where it goes.**
  - Apple Music, no live library: iOS opens the existing Sync Apple Music
    alert, and web opens Step 3's sync page.
  - Spotify, nothing requested: Step 3's Exportify page in Library mode.
  - Spotify data export requested and not landed: the import sheet.
  - Unknown platform: Step 1 in Library mode.
  - Every route returns to the mix it was opened from.
- **The line follows the run.**
  - Syncing (alert hidden): "**Syncing Apple Music… 42%.** You can keep
    chatting while it runs." A thin plum bar sits under the text. There is
    no action.
  - Failed: "Sync didn't finish." in error ink, with "Try again" (the sync
    glyph). Try again reopens the alert at its confirm.
  - Spotify waiting: "Waiting on your Spotify data. It can take a few
    days.", with "Choose files" (the file glyph).
  - Music in: "**Your music is in.** This mix was made before it.", with the
    tape button "Remake with my music" (with a reel).
  - Remade: the line and the header label are gone.
- **The remake.**
  - The listener's line is "Remake this with my music". The working state is
    the approved cassette.
  - The DJ's reply states how many songs are theirs, counted by the server.
  - It makes a new version, and the earlier version stays in Versions.
  - If nothing usable came in, no version is made, the DJ says so, and the
    line returns to its first state.
- **The history pill.** "Add my listening history" is an IdeaPill under that
  DJ line, where album pills go. It shows at most once per conversation.
- **Web.**
  - The line and action sit under the last DJ turn, as a hairline pill
    (`.conversation-pills` style) with the service mark.
  - Remake uses the web primary button.
  - The desktop banner reads "Not personal yet" with "From Mixtape's catalog
    for now." and no action.
  - The phone-shell banner carries the full line and the action.
- **Accessibility.**
  - The line is one container and one live region: the line, then the
    action as a button.
  - Sync is announced at start and end, never per percent.
  - At large text the line wraps in full and the action goes full width,
    with a 44 pt target.
  - Remake's accessible hint is "Makes a new version from your music."
  - States are said in words, never in colour alone.

## Platform differences

- **Apple Music sync.** iOS opens the alert over the conversation. Web goes
  to Step 3's sync page, because web's MusicKit authorisation needs its own
  page.
- **Remake button.** iOS uses the tape button. Web uses its primary button.

## Not covered

- Home starters that need your music, and Welcome copy: the next slice.
- The Exportify, data-export, Apple export and Step 1 pages: unchanged.

## Owners

- **iOS:**
  - `client/lib/presentation/screens/{chat_screen,queue_screen}.dart`
  - a new `client/lib/presentation/widgets/music_door.dart`
  - a new `client/lib/presentation/add_music/add_music_router.dart`
  - `client/lib/presentation/providers/dj_providers.dart`
- **Web:**
  - `web/src/components/{Conversation,QueuePanel}.tsx`
  - a new `web/src/components/MusicDoor.tsx`
  - `web/src/App.tsx`
  - `web/src/components/first-run/FirstRun.tsx`
- **Server:**
  - `server/src/routes/{onboarding,sessions}.ts`
  - `server/src/dj/loop.ts`
  - migration `0048`

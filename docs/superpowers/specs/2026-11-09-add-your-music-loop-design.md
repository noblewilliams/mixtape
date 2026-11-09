# Add your music: label, link, remake

Date: 2026-11-09. Status: approved (founder, 2026-11-09). Board
`docs/mockups/2026-11-09-add-your-music-loop.html`, approval
`docs/mockups/approved/2026-11-09-add-your-music-loop.md` (remake as the
tape button, 3A). Plan: `docs/superpowers/plans/2026-11-09-add-your-music-loop.md`.

## Why

Listeners who skip adding music get catalog mixes and never learn that their
own music makes the DJ better. Today the only pitch is one line on first-run
Step 1 ("Mixes get better when the DJ knows your music."). Most people never
reach that page: they type a prompt on Welcome. After that:

- Every catalog mix is labelled "Not personal yet". The explanation under it
  is plain text with no link, on the chat (`_NotPersonalLine`), on the tape
  (`_NotPersonalBlock`) and on the web mix panel (`.banner`). It still says
  "Import your Spotify data for the real thing", including to Apple Music
  listeners and to listeners who never did the interview it mentions.
- Nothing links from a mix to the step that adds music. Library's "Add your
  music" is three taps away and starts at Step 1, even when we already know
  the listener's service.
- When music does land, nothing shows the difference. The old mixes stay
  catalog mixes, and the label never clears (`markNotPersonal` only ever
  sets it).

The album DJ already has the pattern this program reuses: an honest reply
plus an "Add my music" pill that both clients turn into a link
(`server/src/albums/loop.ts` `EMPTY_SHELF_SUGGESTIONS`).

## The loop

1. **Label.** A catalog mix says so, and says what their music would change.
2. **Link.** One tap goes to the exact step that adds their music, chosen
   from what we already know about them, and comes back to the mix.
3. **Remake.** Once their music is in, the same mix offers "Remake with my
   music". The DJ rebuilds it from their music and says how many songs are
   now theirs. The label clears.

## Decisions

1. **One door on every catalog mix.** The plain-text explanation becomes a
   door: one line and one action, worded for the listener's platform.
   - Line: "From Mixtape's catalog for now. With your music, the DJ picks
     from what you actually play."
   - Action, by device platform (`musicPlatformProvider` on iOS; on web,
     `chosenService`, then a live Apple library):

     | Platform | Action |
     |---|---|
     | Apple Music | Apple Music mark, "Sync Apple Music" |
     | Spotify | Spotify mark, "Add Spotify music" |
     | Unknown | "Add your music" |

   - Where it shows: in the conversation, under the last turn (replacing
     `_NotPersonalLine`), and on the tape screen (replacing
     `_NotPersonalBlock`). The header subtitle "Not personal yet" stays as
     the label, not a link.
   - The labels reuse the 2026-11-09 Library wording ("Sync Apple Music",
     "Add Spotify music"), so the same action has one name everywhere.
   - It is honest labelling, not a pitch, so it shows on every catalog mix
     and has no dismiss. It never blocks a mix: never-refuse stays the floor.

2. **One router, never Step 1 when we know better.** Each client gets one
   function that opens the right step and returns to where it was opened.

   | Listener | Opens |
   |---|---|
   | Apple Music, no live Apple library | iOS: the Sync Apple Music alert (`showLibrarySync`). Web: Step 3's Apple sync page. |
   | Spotify, nothing requested yet | Step 3's Exportify page (minutes), in library mode |
   | Spotify, data export requested and still waiting | the import sheet ("Choose files"), for when the email arrives |
   | Unknown platform | Step 1, in library mode |
   | The history pill (decision 5) | Step 3's data-export page: Spotify's, or "Upload an Apple export" (iOS only; the web has no Apple export import, so a web listener on Apple Music gets no pill) |

   - Library mode already pops back to the opener (`_popAddMusic` on iOS,
     `mode: 'add'` on web). The web flow gains a `startAt` so it can open
     at Step 3.
   - On iOS, playback and sync share the Media Library permission
     (`MusicKitBridge.swift` `requestAuthorization`). A listener who has
     played a mix through Apple Music gets the sync with no new system
     prompt.
   - Onboarding state is refreshed when the alert closes and when the flow
     pops, so the door changes without leaving the mix.

3. **The door follows the run.** It reflects the run it started, in place.
   Words carry the state, never colour alone.

   | State | Line | Action |
   |---|---|---|
   | No music | "From Mixtape's catalog for now. With your music, the DJ picks from what you actually play." | platform action |
   | Apple sync running (alert hidden) | "Syncing Apple Music… 42%. You can keep chatting while it runs." | none |
   | Apple sync failed | "Sync didn't finish." | "Try again" (opens the alert at its confirm) |
   | Spotify data export waiting | "Waiting on your Spotify data. It can take a few days." | "Choose files" |
   | Music in, mix still from the catalog | "Your music is in. This mix was made before it." | "Remake with my music" |
   | Remade (flag cleared) | the door is gone | none |

   - Permission denied stays in the alert (its existing denied title and
     Settings link). The door returns to "No music".
   - Leaving the Exportify page without importing returns to the mix with
     the door unchanged.
   - A finished sync re-reads onboarding itself. Until that read lands, the
     door still says "Syncing", so it never flashes "No music" before
     "Music in" (and the live region speaks once at the end).
   - "Choose files" shows whenever the Spotify export is waiting, whatever
     the device plays on, so the door's action always lands on the import
     sheet then.
   - "Sync didn't finish" shows only on an Apple Music (or unknown)
     device. On a Spotify device a failed Apple sync never replaces the
     Spotify states.
   - `music_added_from_mix` (decision 7) counts only a run the router
     opened: a sync started from its alert (followed past Hide to its end)
     or a page it pushed. The alert closed with nothing started, or a sync
     that failed or was cancelled, counts nothing. A failed onboarding read
     decides nothing: the run stays counted-if-ready until the next good
     read, or until the router opens again.

4. **Remake with my music.** The payoff that proves the label.
   - Shown when the session is `notPersonal` and the listener's music is
     ready (`musicReady`, decision 6).
   - The tap sends a normal turn. The transcript shows the listener's line
     "Remake this with my music". The request carries `remake: true`.
   - Server: a remake turn adds a note telling the DJ to call
     `generate_queue` with the current mix's brief, length and shape, from
     their own music. The result note tells the DJ how many songs are theirs
     ("12 of these 15 are yours, 3 are new to you"), counted from the
     outside-pick marks the queue already carries (`newToYou`). The DJ writes
     its own words around it.
   - It is a new version, so the catalog version stays in Versions and can
     be restored.
   - **The label rule changes:** a whole-mix generate sets `notPersonal`
     from its own pool mode (true for corpus or proposed picks, false for a
     personal pool). Edits still only ever set it. This is what clears the
     label after a remake, and after any fresh mix made once music is in.
   - If the pool is still corpus (the synced library had nothing usable),
     no version is written and the DJ says their music isn't usable yet. The
     door then shows "No music" again, because `musicReady` is false.
   - A remake is a turn, not a new mix, so it does not count against the
     anonymous three-mix cap.

5. **The DJ is honest when the brief needs their music.**
   - **Catalog listener, own-music brief** (familiarity `comfort` or
     `allowOutside: false`, such as "my favourites" or "songs I love"): a
     note tells the DJ to say plainly that it doesn't know their favourites
     yet. The door below the reply already says what their music would
     change and links to it, so the DJ doesn't repeat it, and there is no
     extra pill.
   - **Listener with music but no plays, own-music brief.** No plays means
     no `listening_days` rows and no `user_tracks` row with
     `play_count_observed` true and `play_count` above zero.
     - Today that is a Spotify listener with Exportify only (likes and
       playlists), or an Apple listener synced only on the web, where
       MusicKit JS cannot see play counts.
     - An iOS Apple Music sync observes play counts, so those listeners
       never see this.
     - A note tells the DJ to say these come from their library or likes,
       and that their listening history would show what they actually play.
     - The turn response carries `addMusic: 'history'`.
     - The client shows one pill under that DJ line: "Add my listening
       history". The router opens the data-export page for their platform:
       Spotify's, or "Upload an Apple export" for Apple.
     - At most once per conversation (`dj_sessions.music_chip_at`).
   - DJ wording is the model's. The notes fix the facts it must say, not
     the sentences.

6. **`musicReady` on onboarding.** `GET /onboarding` gains
   `musicReady: boolean`: true when `resolvePoolMode` would pick the
   personal pool. The client cannot tell this from the sources list alone
   (a source can hold nothing usable). The door and the remake read it.

7. **Measure it.** Migration `0048` adds funnel types and the chip column:
   - Client: `music_door_tapped`, `music_chip_tapped`,
     `music_added_from_mix` (music landed in a run the router opened),
     `remake_tapped`.
   - Server: `music_chip_offered`, `remake_made` (a remake landed a
     personal version).
   - `dj_sessions.music_chip_at timestamptz` (nullable).
   - The door is shown on every catalog mix, so a "shown" event would only
     restate `dj_sessions.not_personal`. The funnel counts catalog sessions
     from the table instead.

8. **Web, the same loop.**
   - The conversation shows the door under the last DJ turn, like iOS.
   - The mix panel's banner keeps the "Not personal yet" label. It carries
     the action only in the phone shell, where the panel covers the
     conversation. On desktop, the panel sits beside the conversation, and
     one door per visible screen is enough.
   - The history pill uses the conversation's existing pill row
     (`.conversation-pills`).

## Surfaces

- **iOS.**
  - A `MusicDoor` widget replaces `_NotPersonalLine` (chat) and
    `_NotPersonalBlock` (tape).
  - The router lives in one file, used by the door and the history pill.
  - `ChatNotifier.send` gains `remake`.
  - The mix chat renders `addMusic` as an `IdeaPill` under the last DJ line
    (the album pill row, now for mixes too).
  - Funnel events go through `funnelProvider`.
- **Web.**
  - A `MusicDoor` component in `Conversation` and in `QueuePanel` (phone
    shell).
  - The router lives in `App.tsx` beside `openAddMusic`. `FirstRun` gets a
    `startAt` for add mode.
  - `sendMessage` gains `remake`.
- **Server.**
  - `routes/onboarding.ts` adds `musicReady`.
  - `routes/sessions.ts` accepts `remake` and returns `addMusic`.
  - `dj/loop.ts`: the remake note and count note, the own-music notes, the
    label rule, the chip condition and `music_chip_at`.
  - Migration `0048`.

## Accessibility

- **The door.** It is one container with one live region. Its accessible
  text is the line, then the action as a button ("Sync Apple Music,
  button").
  - Sync progress is announced at start and end, never every percent.
  - At large text the line wraps and the action goes full width.
- **Every action** has a 44 pt target.
- **The remake** reuses the working cassette and its "The DJ is working"
  announcement. The hubs stand still under reduced motion.
- **No state is shown by colour alone.** Failed and waiting states say so in
  words.

## Out of scope

- Personal starters on Home ("My 2019 on repeat") and benefit-first
  onboarding copy: the next slice, if this loop moves the funnel.
- Labels on Mixes rows, push or email nudges, Apple export as a rung.

## Tests

- **Server**, structural (the golden-set rule):
  - a remake turn generates once with the current brief and writes a
    version;
  - a personal generate clears `notPersonal`, and an edit never does;
  - the chip appears only for listeners with no plays and an own-music
    brief, once per session;
  - `musicReady` matches `resolvePoolMode`;
  - catalog own-music briefs carry the honesty note;
  - migration `0048` round-trips.
- **iOS**, widget tests:
  - each door state by platform;
  - the router's destination per listener;
  - remake sends `remake: true` and the door leaves when the flag clears;
  - the history pill opens the data-export page.
- **Web:** the same states in `Conversation`, `QueuePanel` (phone shell) and
  the router.

## Build notes

- As of 2026-11-09, another session holds uncommitted work in
  `server/src/dj/` (`loop.ts`, `contracts.ts`, `pool.ts`, `propose.ts`,
  `curate.ts`, `queue-store.ts`) and their tests. Server tasks that touch
  `loop.ts` wait for that work to be committed, or run in a worktree from
  committed HEAD.
- Migration `0048` assumes nothing else lands first. Check `server/drizzle`
  before generating it.
- The deploy follows the standing rule: from a clean worktree of committed
  HEAD, migrate before deploy, with the founder's go at action time.

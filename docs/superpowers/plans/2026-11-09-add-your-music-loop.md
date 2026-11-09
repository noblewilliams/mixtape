# Add your music: label, link, remake — plan

**Status:** approved 2026-11-09 (founder: "Approve, plan it").
- Spec: `../specs/2026-11-09-add-your-music-loop-design.md`.
- Board: `../../mockups/2026-11-09-add-your-music-loop.html`.
- Locked record: `../../mockups/approved/2026-11-09-add-your-music-loop.md`
  (remake is the tape button, 3A).
- Decision: `../../decisions.md` → 2026-11-09 Add your music.

**Cadence:** house style. Each task goes to a fresh implementer agent
(Opus) with red-first tests. Then a reviewer pass and one fix round, then
one commit per task, with files staged by explicit path. At most two agents
in flight.

**Order:** Server S1 → S2 → S3 → S4. The clients need only the shared
contract below, so iOS C1 → C2 → C3 and web W1 → W2 can run beside the
server track. S3 and S4 must not run at the same time: both edit
`dj/loop.ts`.

## Before starting

- **Another session's server work.** On 2026-11-09 another session held
  uncommitted changes in `server/src/dj/` (`loop.ts`, `contracts.ts`,
  `pool.ts`, `propose.ts`, `curate.ts`, `queue-store.ts`) and their tests,
  plus the client import, first-run and Library files.
  - Server tasks start only once that work is committed. Otherwise they run
    in a worktree cut from committed HEAD.
  - Never stage another session's hunks. `docs/decisions.md` and
    `docs/backlog.md` carry its uncommitted entries too.
- **Migration number.** Check `server/drizzle/` for the highest number
  before S1. The plan assumes `0048`.
- **Formatting.** Never run `dart format` on a folder. Format only the files
  the task touched.

## Shared contract

- **Onboarding.** `GET /onboarding` adds `musicReady: boolean`. It is true
  when the listener has a music source or library (as `resolvePoolMode`
  reads it) and `hasPersonalCandidates` is true.
- **Remake request.** `POST /sessions/:id/messages` accepts
  `{ text, remake?: true }`.
  - Mix sessions only. On an album session the route answers 409
    `wrong_session_kind`.
  - Both clients send the text `Remake this with my music` (constant
    `remakeText` / `REMAKE_TEXT`). The server never reads meaning from the
    text.
- **History pill.** Turn responses (create and follow-up) add
  `addMusic: 'history'` only when the history pill is offered. Otherwise the
  key is absent, never null.
- **Funnel types.**
  - Clients may post `music_door_tapped`, `music_chip_tapped`,
    `music_added_from_mix` and `remake_tapped`.
  - Only the server writes `music_chip_offered` and `remake_made`.
- **Router targets** (each client names them the same way):
  - `door`: pick by platform and state;
  - `retrySync`: the alert at its confirm;
  - `history`: the data-export page for the platform.
- **Door states**, in priority order:
  1. `remade`: nothing shown, because `notPersonal` is false.
  2. `musicIn`: `notPersonal` and `musicReady`.
  3. `syncing`: an Apple sync running.
  4. `syncFailed`: the last sync this session failed.
  5. `spotifyWaiting`: Spotify chosen, export requested, no package
     landed, no Exportify package.
  6. `noMusic`: everything else.
- **Copy.** Verbatim from the approval record. No em dashes.

## Server

**S1. Migration 0048: funnel types and the chip column.** About 1 hour.
- Files:
  - `server/src/seeds/contracts.ts`: add the client and server types to
    `CLIENT_FUNNEL_EVENT_TYPES` and `SERVER_FUNNEL_EVENT_TYPES`, in order.
  - `server/src/db/schema.ts`: the funnel enum and its check, plus
    `djSessions.musicChipAt` (`music_chip_at timestamptz`, nullable).
  - `server/drizzle/0048_*.sql` and the journal entry.
- Tests:
  - the contracts order test (the check lists the same values in the same
    order);
  - a funnel route test that accepts each new client type and rejects
    `remake_made` from the client.
- Done when `npm test` and the typecheck are green, and the generated SQL
  only drops and re-adds the funnel check and adds the column.

**S2. `musicReady` on onboarding.** About 1 hour.
- Files:
  - `server/src/dj/pool.ts`: an exported `musicReady(db, userId)`. It reuses
    the `has_source` / `has_library` EXISTS checks without the seed CTE, then
    `hasPersonalCandidates`.
  - `server/src/routes/onboarding.ts`: add the field to the response.
- Tests (route), for:
  - no music: false;
  - a synced library with candidates: true;
  - a source row whose tracks the candidate rule rejects: false;
  - Spotify account liked tracks: true.
- Done when the field is present on every response and the existing
  onboarding tests pass.

**S3. Remake and the label rule.** About 3 hours.
- **Route** (`routes/sessions.ts`): parse `remake` (optional boolean) on
  `/:id/messages`, apply the album 409, and pass it in `DjTurnOptions`.
- **Loop** (`dj/loop.ts`):
  - **The note.** `DjTurnOptions.remake` adds `REMAKE_NOTE` to what the
    model sees this turn. It is not persisted as transcript. It tells the
    DJ to call `generate_queue` with the current mix's brief, length and
    shape, from the listener's own music.
  - **The count.** After a remake's generate lands a personal pool, append
    `remakeCountNotice(yours, total)` to its tool result ("note: N of
    these M songs are the listener's own, the rest are new to them. Say
    so in one line."). `yours` counts landed picks that are not outside
    picks.
  - **Nothing usable.** A remake whose pool resolves corpus or
    insufficient: no generate and no version. The tool result says their
    music isn't usable yet.
  - **The label rule.** A new `setNotPersonal(db, sessionId, value)` sets
    the flag on every whole-mix generate (proposed, generate, only-artist,
    curated): true when corpus picks or proposed picks landed, false for a
    personal pool. Edits keep calling `markNotPersonal` (set only). As
    before, it skips a row that already says so.
  - **Funnel.** Record `remake_made` (server, surface from the request)
    when a remake lands a personal version.
- Tests:
  - a remake on a catalog session with a library now present generates
    once, writes version n+1, clears `notPersonal`, and the model input
    carries the note;
  - the count notice matches the landed outside marks;
  - a remake with no usable music writes no version and keeps the flag;
  - an edit on a personal session after a catalog mix never clears the
    flag;
  - a plain new generate with a library clears it;
  - the album 409.
- Structural assertions only, never exact tracks (the golden-set rule).

**S4. Own-music honesty and the history pill.** About 2 hours. Runs after
S3, in the same file.
- `dj/loop.ts`:
  - **Catalog listener, own-music brief.** An own-music brief has
    `outsideCap({...intent, targetCount: 100}) === 0`, the gate the
    shortfall already uses. Append `OWN_MUSIC_CATALOG_NOTICE`: say plainly
    you don't know their favourites yet, and don't pitch adding music,
    because the client shows that line.
  - **Personal listener, own-music brief, no plays, pill not yet offered.**
    No plays is a new `hasPlays(db, userId)`: no `listening_days` rows and
    no `user_tracks` row with `play_count_observed` true and
    `play_count > 0`. Not yet offered means `music_chip_at` is null.
    - Append `HISTORY_NOTICE` (these come from their library or likes;
      their listening history would show what they actually play).
    - Set `addMusic: 'history'` on `DjTurnResult`.
    - Write `music_chip_at`.
    - Record `music_chip_offered`.
- `routes/sessions.ts`: spread `addMusic` onto both turn responses, only
  when set.
- Tests:
  - the notice for catalog own-music briefs, and none for a mix brief;
  - the pill only for a no-plays listener, once per session (a second
    own-music turn in the same session gets the notice text but no
    `addMusic`);
  - never for a listener with observed plays or ledger rows;
  - absent from the response otherwise.

## iOS

**C1. Data layer.** About 1 hour.
- `client/lib/data/listening/listening_models.dart`:
  - `OnboardingState.musicReady`, defaulting to false when the key is
    missing;
  - the four new client values in `FunnelEventType`.
- `client/lib/data/dj/dj_models.dart`: `TurnResult.addMusic` and
  `SessionDetail.addMusic` (a nullable enum, `history`).
- `client/lib/data/dj/dj_api.dart`: `api.sendRemake(id)` posts
  `{text: remakeText, remake: true}`. `sendMessage` is unchanged.
  - Built as an extension (`DjApiRemake`) over a private `_sendRemake`,
    with an opt-in `DjRemakeSender` interface for fakes.
  - Every test fake implements `DjApi`, and one sits in another session's
    uncommitted file, so any new `DjApi` member would break them.
  - Fold it into `DjApi` once all fakes can be updated together. The
    instance member then wins over the extension, with no caller change.
- `client/lib/presentation/providers/dj_providers.dart`:
  - `ChatNotifier.remake()`, through the same send pipeline as `send`;
  - `ChatState` keeps the last turn's `addMusic`, cleared by the next send,
    as album suggestions are.
- Tests: parsing with and without each key; `remake()` posts through
  `sendRemake`; `addMusic` clears on the next send.

**C2. Router and `MusicDoor`.** About 4 hours.
- **Router** (new `client/lib/presentation/add_music/add_music_router.dart`):
  `Future<void> openAddMusicFor(BuildContext context, WidgetRef ref,
  AddMusicTarget target)`.
  - **Picking the destination.** It reads `musicPlatformProvider`,
    onboarding and `librarySyncProvider`. The destination table is in the
    spec, decision 2.
    - Apple: `showLibrarySync`.
    - Spotify: `DoingScreen(method: AddMethod.exportify, mode:
      AddMusicMode.library)`, pushed with the `add-music/` route name so
      `_popAddMusic` returns to the mix.
    - Spotify waiting: `openImportFlow`.
    - Unknown: `openAddMusic`.
    - History: `DoingScreen` with `spotifyExport` or `appleExport`.
  - **Afterwards.** When the destination closes, refresh onboarding.
  - **Funnel.** Record `music_door_tapped` on entry, or `music_chip_tapped`
    for `history`. Record `music_added_from_mix` when `musicReady` went
    from false to true across the call.
- **`MusicDoor`** (new `client/lib/presentation/widgets/music_door.dart`):
  - It takes the session's `notPersonal` and a `layout: transcript | tape`,
    and watches the providers above for its state (contract).
  - It draws the line and action as the approval record locks them:
    IdeaPill with the service mark, the plum progress bar while syncing,
    error ink with Try again, and the tape button with a reel for Remake.
  - **Semantics:** one container, a live region, and announcements at sync
    start and end only. The remake hint is "Makes a new version from your
    music."
- **Wiring:**
  - `chat_screen.dart`: replace `_NotPersonalLine` with
    `MusicDoor(layout: transcript)`.
  - `queue_screen.dart`: replace `_NotPersonalBlock` with the tape layout
    under its "Not personal yet" title.
  - The header subtitle is unchanged.
- **Tests** (widget):
  - each state × Apple, Spotify and unknown, with the exact labels and
    marks;
  - the router's destination per listener, with fakes for the alert, push
    and import flow;
  - largest text wraps and goes full width;
  - semantics labels;
  - the door disappears when `notPersonal` is false.

**C3. Remake and the history pill in the chat.** About 2 hours.
- `chat_screen.dart`:
  - The door's Remake calls `notifier.remake()` and records
    `remake_tapped`. It is disabled while sending.
  - The same applies on the tape screen (`queue_screen.dart`), which
    passes no `onRemake` after C2 and so draws Remake disabled. Moved here
    by the C2 review.
  - Resend (the failed-turn link) and the AI-consent retry call `remake()`
    when the failed message carries C1's `remake` marker. Otherwise
    `_send` would post a remake without its flag.
  - `chat_screen_test.dart`'s `FakeDjApi` must implement `DjRemakeSender`.
    Without it, a remake test that only checks the optimistic line passes
    while nothing was posted (a `NoSuchMethodError` swallowed by the
    handler).
  - Carry the create response's `addMusic` into the new chat's state.
    `sessionStarterProvider` returns only the id today, and `GET
    /sessions/:id` never carries the key, so a pill offered on the first
    turn ("play my favourites") would be lost. Found in C1.
  - When `state.addMusic == history`, the pill row under the last DJ line
    (the album row, generalised) shows "Add my listening history", which
    opens `openAddMusicFor(history)`.
  - After the remake turn, the existing post-turn refetch of `notPersonal`
    (ChatNotifier, the "one flag a turn can flip") removes the door and the
    header label.
- Tests:
  - tapping Remake shows "Remake this with my music" as the listener's
    line, then the working cassette;
  - a turn result with `notPersonal` false removes the door;
  - the pill appears only with `addMusic`, and is gone after the next send.
- Then a simulator pass of 1A → 2A → 3A → 3D against a local API
  (`api` launch config). The founder smokes the device run at gate G3.

## Web

**W1. Data and router.** About 3 hours.
- `web/src/api/client.ts` and `web/src/domain.ts`: `musicReady`,
  `addMusic`, `sendMessage(..., { remake })`, and the four client funnel
  types. Also `web/src/test/fake-api.ts`.
- `web/src/components/first-run/FirstRun.tsx`: `startAt?: AddMethod`
  (`'apple-sync' | 'exportify' | 'spotify-export'`, the web's existing
  methods) for `mode: 'add'`. It opens Step 3 directly, and back from there
  leaves the flow.
- **Amendment, 2026-11-09:** the web has no Apple export import, so on the
  web the history destination exists only for Spotify. A web listener on
  Apple Music gets no history pill; the DJ's spoken line still stands.
- **Amendment, 2026-11-09 (W1 review):** the web has no import sheet, so
  Spotify-waiting opens Step 3's Exportify page. Its Choose files takes the
  Spotify data ZIP too, and its Done returns to the mix.
  - The history pill does the same when the listener already requested
    their data.
  - Known limit: that page's headline and steps talk about Exportify. A
    dedicated "Choose files" Step 3 page needs founder copy and is a
    follow-up (backlog).
- The destination choice is a pure function,
  `web/src/lib/add-music-route.ts`, unit-tested on its own. `App.tsx` wires
  it.
- `web/src/App.tsx`:
  - `openAddMusicFor(target)` beside `openAddMusic`. Its platform comes from
    `playsOn`, then `chosenService`, then a live Apple library. Spotify
    waiting opens the existing Choose files import.
  - It refreshes onboarding when the flow finishes, records the funnel
    events as on iOS, and returns focus to the opener.
- Tests: the router's destination per listener, `startAt` per method,
  `remake` in the request body.

**W2. `MusicDoor`, remake and the pill.** About 3 hours.
- New `web/src/components/MusicDoor.tsx`, with the states from the contract
  and the copy from the approval record.
  - The action is a `.conversation-pills`-style button with the service
    mark.
  - Remake is the primary button.
  - It has `role="status"` for state changes.
- `Conversation.tsx`: the door under the last DJ turn on catalog sessions,
  and the history pill through the existing suggestions row
  (`onSuggestion`). Album string matching stays as it is.
- `QueuePanel.tsx`:
  - The banner keeps "Not personal yet", with "From Mixtape's catalog for
    now." on wide screens, and no action there.
  - Under the 1020 px breakpoint (`narrow`), it carries the full line and
    the door's action.
- Check with the `web-preview` launch config and `?ui-preview` at 390 px
  and desktop, in light and dark, against W1–W3 on the board.
- Tests: door states, wide vs narrow banner, remake send, pill.

## Gates (founder, at action time)

- **G1.** Apply migration `0048` from a clean worktree of committed HEAD,
  with `DATABASE_URL` from `server/.dev.vars` (production Neon). Then deploy
  the Worker from the same worktree. Smoke-test with a throwaway anonymous
  user:
  - `GET /onboarding` has `musicReady: false`;
  - a mix is catalog;
  - `remake: true` with no music writes no version;
  - then delete the user.
- **G2.** Netlify publishes `main`. Run one private-window pass: a catalog
  mix shows the door, and Sync Apple Music opens Step 3.
- **G3.** TestFlight build, then a device run: catalog mix → Sync Apple
  Music → music in → Remake → the label clears.

## Docs and close-out

- In each task's commit, keep the spec in step if anything moves.
- At the end:
  - add a `docs/backlog.md` line for anything left open;
  - record the funnel query for the four client events against
    `dj_sessions.not_personal` counts in the backlog, for the
    reopen-clause check.

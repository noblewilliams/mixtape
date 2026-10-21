# Plan: album picks and Listen later

Date: 2026-10-20. Spec: `../specs/2026-10-20-album-picks-design.md`.
Board approval: `../../mockups/approved/2026-10-20-album-picks.md`.
Decision: `../../decisions.md` → 2026-10-20 (album picks).

House cadence: one fresh implementer per task, red tests first, then a
reviewer pass and one fix round. Implementers and reviewers run on Opus. At
most two agents in flight. One commit per task, files staged by explicit
path, one-line commit subjects.

## Standing rules for every task

- **Shared working tree.** Other sessions may hold uncommitted work
  (`docs/mockups/2026-09-25-tape-materials*.html`, the rack assets, and the
  first-run flow work are not ours). Edit in place. No `git stash`,
  `checkout`, `restore`, `reset`. Stage only the task's files.
- **No production writes, no deploy, no migration apply** unless a step says
  the founder runs it. Deploys come from a clean worktree of committed HEAD.
- **Flag off until Gate 2.** `ALBUM_PICKS` is declared under `vars` in
  `server/wrangler.jsonc` as `"off"`, read once per request in
  `server/src/index.ts` like `OUTSIDE_PICKS`, and passed to the deps. With
  it off, `POST /sessions` with `kind: 'album'` is 404 `album_picks_off`,
  the Listen later routes are 404, and clients hide the control when
  `GET /me` (or the existing capabilities payload) says albums are off.
- **Free plan limits stand.** A turn makes at most six Apple catalogue calls
  (five album searches, one album fetch) and the same model and embedding
  calls as a mix turn. Nothing new runs on the cron.
- **Schema is platform-agnostic.** `albums` is keyed by internal id plus UPC;
  `apple_id` is one column among future peers. No Spotify album ids exist.
- New listener-facing strings contain no em dashes; the DJ's replies pass
  through `stripEmDashes`. Copy comes from the board verbatim.
- Never store or display lyric text. Album picks carry no lyrics.
- iOS user-scoped providers `ref.watch(authProvider)` in `build()`; new Swift
  files get pbxproj target membership.
- Golden-set tests assert structure (verified, labelled, capped, honest),
  never an exact album.
- Docs ride with the change: the spec's status line when a phase lands, and
  `docs/backlog.md`.

## Phase 1: server, behind the flag

### Task 1: catalogue album calls

Files: `server/src/musickit/catalog.ts`, `server/test/musickit/catalog.test.ts`
(or the nearest existing catalogue test).

- Add `CatalogAlbum` (`appleId`, `upc`, `title`, `artist`, `releaseYear`,
  `trackCount`, `durationMs`, `isSingle`, `isCompilation`, `genre`,
  `artwork`) and two client methods on a new `AppleCatalogAlbumClient` type:
  `searchAlbums(storefront, term, limit)` (`/v1/catalog/{sf}/search` with
  `types=albums`, limit 1 to 10) and `getAlbums(storefront, ids)`
  (`/v1/catalog/{sf}/albums?ids=`, at most 100 per call, `durationMs` summed
  from the album's tracks relationship when present, else null).
- Same bounded JSON reading, timeout and error categories as the song calls.
  Parse defensively: an album without `name` or `artistName` is dropped.
- Tests: fixture payloads for a search hit, a single, a compilation, a
  malformed item, and an upstream 429; the term and id bounds are enforced.

### Task 2: schema and the album picks migration

Files: `server/src/db/schema.ts`, new `server/drizzle/NNNN_album_picks.sql`
plus the journal entry (NNNN is the next free number when the task starts:
0037 belongs to the first-run flow's `session_merged_mode`, so expect 0038), `server/test/db/*` (the schema shape test if one
exists).

- `albums`: id uuid pk, upc text, apple_id text, apple_catalog_storefront
  text (storefront check as `tracks`), title, artist (not null), release_year
  int, track_count int, duration_ms int, type text check in
  (`album`,`ep`,`single`,`live`,`compilation`,`soundtrack`,`mixtape`),
  artwork columns as on `tracks`, created_at. Unique on `apple_id` where not
  null; index on `upc`.
- `dj_sessions.kind` text not null default `'mix'`, check in
  (`mix`,`album`).
- `album_picks`: id, session_id fk cascade, version int > 0, rank int >= 0
  (0 is the pick), album_id fk, reason text, new_to_them boolean, created_at;
  unique (session_id, version, rank); index (session_id, version desc).
- `listen_later`: user_id fk cascade, album_id fk, session_id nullable fk
  set null, saved_at, listened_at nullable, removed_at nullable; pk (user_id,
  album_id); index (user_id, removed_at, listened_at, saved_at).
- `session_events.type` enum and check gain `album_saved`, `album_unsaved`,
  `album_passed`, `album_listened`.
- Generated with drizzle-kit, checked by hand against 0035 and 0036.

### Task 3: shelf candidates

Files: new `server/src/albums/shelf.ts`, new `server/test/albums/shelf.test.ts`.

- `buildShelf(db, userId, briefEmbedding, { minSongs: 4, limit: 10 })`:
  group the listener's pool candidate rows (reuse the personal candidate rule
  from `dj/pool.ts`, exported if it is not yet) by `tracks.artist` and
  `tracks.album` (both trimmed, case-folded), keep groups with at least four
  songs, score by mean cosine similarity of the group's `track_meanings`
  embeddings to the brief (one SQL statement with the existing pgvector
  operator), plus a play-count and recency term in the corpus-mode style.
  Returns `ShelfAlbum[]` (`artist`, `album`, `songCount`, `plays`,
  `similarity`, `sampleAppleIds`).
- Rows whose `album` is null or a single-song group are never shelf
  candidates.
- Tests: seeded listener with three album groups of varying sizes; the
  four-song floor; ordering by similarity; an empty library returns `[]`.

### Task 4: the album loop

Files: new `server/src/albums/loop.ts`, new `server/src/albums/contracts.ts`,
new `server/src/albums/verify.ts`, new `server/src/albums/store.ts`,
`server/src/dj/llm.ts` (tool definitions export only), new
`server/test/albums/{loop,verify,store}.test.ts`.

- `runAlbumTurn(db, deps, session, userText, options)` mirrors `runDjTurn`'s
  shape (transcript load, memory notes, title fallback, request fencing)
  with tools `recommend_album`, `remember_preference`, `rename_session`, and
  none of the queue tools. Persona: the DJ voice, no em dashes, one album.
- `recommend_album` input (`contracts.ts`, zod and the JSON Schema twin with
  an agreement test): `familiarity` (`comfort`|`mix`|`adventurous`),
  `candidates[1..5]` of `{ artist, title, year?, type, why }`, optional
  `fromShelf` naming a shelf group. The context block lists the top ten
  shelf albums with song counts and plays.
- `verify.ts`: for each candidate, `searchAlbums(market, "{artist} {title}",
  5)` in the listener's market with the default-storefront fallback used by
  linking; match on folded artist and title (punctuation and bracketed
  suffixes stripped, "deluxe"/"remastered" tolerated); drop `isSingle` unless
  the candidate's type is `single`; the model's type stands unless Apple's
  `isSingle` or `isCompilation` says otherwise. Shelf picks resolve the same
  way from the group's artist and album name. Unverified candidates are
  dropped and counted.
- Rank in code: comfort keeps shelf-resolved albums only; adventurous puts
  catalogue albums first; otherwise interleave by the model's order, then
  artist affinity (the listener holds other songs by the artist), then a
  penalty for albums already on Listen later or passed over in this session.
  Rank 0 is the pick, 1 and 2 the runners-up. `newToThem` is true when the
  listener holds none of the album's songs (by `tracks.album` and artist
  match against their rows; exact per-song membership waits for a track
  list).
- `store.ts`: upsert `albums` on `apple_id`, write the version's
  `album_picks` rows in one transaction with the DJ message, bump
  `dj_sessions.queue_version` as the pick version so mix history's fencing
  applies; `choosePick(sessionId, albumId)` and `goBack(sessionId, version)`
  write a new version without a model call and record `album_passed`.
- Tool result tells the model which album was chosen, which were runners-up,
  how many were dropped, and whether the pick is new to them, so the reply is
  in words; the loop strips em dashes.
- Honest failures: zero verified returns the model's plain reply with the
  board's refinement pills as `suggestions[]`; comfort with an empty shelf
  short-circuits before the model with the board's message and pills;
  catalogue errors become the failed-turn result naming the step.
- Tests (golden set, structural): a pick is never returned without a verified
  album; unverified candidates are dropped; comfort yields shelf only or the
  honest message; adventurous yields a catalogue album when any verifies;
  type override by Apple's flags; `newToThem` false for a shelf album; passed
  and saved albums rank last; at most six catalogue calls per turn (fetch
  counter); no em dashes in replies.

### Task 5: routes and the flag

Files: `server/src/routes/sessions.ts`, new `server/src/routes/listen-later.ts`,
`server/src/app.ts`, `server/src/index.ts`, `server/wrangler.jsonc`,
`server/test/session.test.ts`, new `server/test/listen-later.test.ts`.

- `createSessionSchema` gains `kind` (`'mix'|'album'`, default mix).
  `POST /sessions` with `kind: 'album'` runs `runAlbumTurn`; the title job is
  unchanged. `POST /sessions/:id/messages` dispatches on the session's
  `kind`; `energyArc` is ignored for album sessions. Mix-only routes
  (queue ops, arrangement, playlist conversion, mix history versions) return
  409 `wrong_session_kind` for album sessions, and the album routes the
  reverse.
- `GET /sessions/:id` for an album session returns `{ session, messages,
  pick, runnersUp, passed }` where each album carries id, upc, appleId,
  title, artist, releaseYear, type, trackCount, durationMs, artwork,
  newToThem, reason, savedForLater. `GET /sessions` list rows gain `kind`
  and, for album sessions, the current pick's title, artist and artwork so
  the Mixes list can draw them.
- `POST /sessions/:id/pick` `{ albumId }` or `{ version }` (choose a
  runner-up, or go back) with `expectedVersion` fencing.
- `/me/listen-later`: `GET` (unlistened then listened, removed hidden),
  `PUT /:albumId` `{ sessionId? }` (upsert, revives a removed row, records
  `album_saved`), `DELETE /:albumId` (soft, `album_unsaved`),
  `POST /:albumId/listened` (`album_listened`). All keyed by the session
  user.
- The flag: `ALBUM_PICKS` as described in the standing rules; `GET /me`
  (or the capabilities the clients already read) reports `albumPicks:
  boolean`.
- Tests: kind defaults; dispatch; wrong-kind 409s; the album read shape;
  pick and go-back write versions; Listen later save, unsave, re-save,
  listened are idempotent and user-scoped; everything is 404 with the flag
  off.

### Gate 1: the album picks migration and deploy (founder)

Done 2026-10-20 as part of the first-run flow's Gate 1: migration 0038 applied
and Worker `42bffed2` deployed from `859700d` with the flag off. The
`album_picks_off` check on production is still to be run.

From a clean worktree of committed HEAD: apply the album picks migration, deploy the Worker with
`ALBUM_PICKS` off, confirm `GET /sessions` and an ordinary mix still work
and that `POST /sessions` with `kind: 'album'` returns `album_picks_off`.
Clients are unaffected until Phase 2.

## Phase 2: web

### Task 6: API, domain and mappers

Files: `web/src/domain.ts`, `web/src/api/client.ts`, `web/src/api/mappers.ts`,
`web/src/test/fake-api.ts`, tests beside them.

- `SessionKind`, `AlbumPick`, `AlbumSummary`, `ListenLaterEntry` types;
  `createSession` gains `kind`; `getSession` maps the album shape;
  `choosePick`, `listListenLater`, `saveForLater`, `unsaveForLater`,
  `markListened`; the fake API grows matching state for tests and the
  preview harness.

### Task 7: the composer

Files: `web/src/components/PromptComposer.tsx`, `HomeComposer.tsx`, `Home.tsx`,
`HomeDashboard.tsx`, `home-composer.css`, new `ModeControl.tsx`, tests.

- `ModeControl`: a radio group "What to make" with Mix and Album, drawn as
  the view switch pair (hairline outline, quiet current fill, 12 px, 28 px
  tall, 44 px effective on coarse pointers).
- Home's composer gains the tool row with `ModeControl` and the Shape
  control; Shape unmounts under Album and no `energyArc` is sent; the send
  label becomes "Find an album"; the placeholder and the three pills follow
  the mode (board copy). Mode is component state, never persisted.
- The nudge: with Mix selected, when the draft matches `/\balbums?\b/i`,
  switch to Album once and render the status line "Switched to Album for
  this prompt." with the "Keep it a mix" link in place of the pills; a
  manual Mix choice after that suppresses further nudges for the draft.
  `prefers-reduced-motion` removes the segment transition.
- Hidden entirely when the capability says albums are off or the user is
  anonymous.
- Tests: default mode; Shape absent under Album; nudge once and not after
  "Keep it a mix"; anonymous hides; `createSession` called with `kind`.

### Task 8: the album panel

Files: new `web/src/components/AlbumPanel.tsx`, `Conversation.tsx`, `App.tsx`,
`styles.css` (album panel rules beside the queue panel's), `Overlays.tsx`
(toast reuse), tests, and the `?ui-preview` state `album`.

- `App.tsx` routes an album session to `AlbumPanel` where `QueuePanel` would
  mount, with the same width and hairline; no Shape tool in the chat
  composer for album sessions; the "Open the tape" affordances are absent.
- The panel: heading "The album · pick n"; cover 96 px; title, artist, meta
  line with the type label and the "· New to you" mark in the approved
  words-only style (never truncated); the "why"; Play now (filled) which sets
  the MusicKit queue to the album by Apple id through the existing playback
  path; Listen later (quiet, toggles, "Saved for later" when saved, pressed
  state, toast with Undo for four seconds); "Open in Spotify" for
  Spotify-only listeners, opening `https://open.spotify.com/search/{artist
  title}`; runners-up under a hairline with Show/Hide and "Pick this"; the
  passed-over row rendered in the transcript above the replacing turn with
  "Go back".
- Below 760 px the panel renders inline under the reply, as the queue does.
- Failure replies render the pills from `suggestions[]` as the clarification
  chips already do.
- Tests: the panel shape for pick, runners-up, passed; toggle and undo;
  Spotify link; narrow fold; no Shape for album sessions.

### Task 9: Listen later in Mixes

Files: `web/src/components/Home.tsx`, new `ListenLaterList.tsx`,
`Tabs.tsx` (no change expected), `UiStates.tsx`, `styles.css`, tests, preview
states `listen-later` and `listen-later-empty`.

- Third tab "Listen later"; the view switch hidden on it; count line per the
  board; rows with 56 px cover, open button, play button, three-dot menu
  (Open, Mark listened, Remove); "Listened" section label; listened rows
  muted with "Listened {d Mon}" in plum; the empty state with "Find an album"
  which opens Home with Album selected.
- Tests: tab routing, count line forms, section ordering, menu actions,
  empty state.

## Phase 3: iOS

### Task 10: data layer and providers

Files: `client/lib/data/dj/dj_models.dart`, `dj_api.dart`,
`client/lib/presentation/providers/dj_providers.dart`, new
`listen_later_provider.dart`, tests under `client/test/`.

- Session kind, album pick models, Listen later entries and API calls;
  the capability flag from `GET /me`; a user-scoped Listen later provider
  that watches `authProvider` in `build()`.

### Task 11: the Home panel

Files: `client/lib/presentation/widgets/home_panel.dart`, `mix_prompt_input.dart`,
`screens/home_screen.dart`, widget tests.

- The compact row above the composer: the app-wide segmented control (Mix |
  Album) at 26 pt with 11.5 pt labels and a 44 pt hit area, the Shape chip
  trailing at the same height (this compacts the existing chip); the chip is
  absent under Album; pills, placeholder and Send label follow the mode; the
  nudge with the status line and "Keep it a mix"; no control for anonymous
  listeners or when albums are off; reduced motion removes the slide. Mode
  is screen state only.
- Tests: default, Album, nudge once, anonymous, send with `kind`.

### Task 12: the album conversation and playback

Files: `client/lib/presentation/screens/chat_screen.dart`, new
`widgets/album_card.dart`, `widgets/conversation_turn.dart` (passed-over
row), `data/musickit/musickit_bridge.dart`,
`client/ios/Runner/MusicKitBridge.swift`, widget tests, Swift target
membership in `project.pbxproj`.

- The album card per the board (cover 112 pt, meta line with type and mark,
  "why", Play now tape button, Listen later chip with saved state and the
  compact toast with Undo, runners-up row, "Pick this", passed-over row with
  "Go back", "Open in Spotify" for Spotify-only, 1.5x text layout). The
  navbar drops Arrangement for album sessions; the More menu keeps Rename
  and Archive.
- Playback: `playAlbum(appleAlbumId)` on the bridge. App-owned player:
  `ApplicationMusicPlayer.Queue(album:)` after a `MusicCatalogResourceRequest
  <Album>`. System player: queue the album through `SystemMusicPlayer` on iOS
  16 and later; if a device check shows it cannot take an album, fall back to
  fetching the album's songs and the existing `playQueue` over their ids.
  Playback evidence is not recorded for albums in this phase.
- Tests: widget tests for every card state; bridge argument shape.

### Task 13: Listen later in Mixes

Files: `client/lib/presentation/screens/mixes_screen.dart`, new
`widgets/listen_later_row.dart`, widget tests.

- Third segment "Listen later"; flush rows with the 60 pt cover tile;
  long-press expands with the "why", the prompt it came from, and "Mark
  listened"; listened rows under a "Listened" heading with the plum status
  word; swipe to remove with the Undo toast; the empty state with "Find an
  album" opening Home in Album mode; rotor actions Open, Show why, Mark
  listened, Remove.

### Gate 2: flag on and founder briefs

From a clean worktree of committed HEAD, deploy with `ALBUM_PICKS` on. The
founder makes three album briefs (comfort, default, adventurous) on the main
account and one on the Spotify-only test account, saves two to Listen later,
marks one listened, and plays one album on each iOS player. Record the
results in `docs/backlog.md`; reopen per the spec if verification discards
most proposals.

## Later, evidence-gated (not in this plan)

Listened from playback evidence once album playback is observed; weighting
saves, passes and listened into the learned artist term; "Make a mix around
this album"; catalogue growth from album track lists.

## What the founder does, in order

1. After Task 5: Gate 1 (apply the album picks migration, deploy, flag off).
2. After Task 9: look at the web preview states `album`, `listen-later` and
   `listen-later-empty` against the board.
3. After Task 13: Gate 2 (flag on, four briefs, two players).

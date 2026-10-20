# Album picks and Listen later

Status: approved by the founder 2026-10-20 (direction, then the state board
"as drawn" after one revision for compact composer controls). Board:
`../../mockups/2026-10-20-album-picks-states.html`; approval record:
`../../mockups/approved/2026-10-20-album-picks.md`. Plan:
`../plans/2026-10-20-album-picks.md` (server behind `ALBUM_PICKS`, then web,
then iOS, two founder gates). Phase 1, the server behind `ALBUM_PICKS` off,
is committed on `main` (2026-10-20, Tasks 1 to 5); Gate 1 is owed. Decision:
`../../decisions.md` 2026-10-20. Keeps the first-run decision of the same
day (albums stay out of the anonymous flow). Builds on the outside-library
picks spec (`2026-10-03-outside-library-picks-design.md`) for what "new to
you" means, and on the bounded-loop pattern of
`2026-09-05-conversational-source-playlist-editing-design.md`.

## User outcome

The listener tells the DJ how they feel or what they want to hear, exactly as
for a mix, but with the composer set to Album instead of Mix. The DJ answers
with one album: artwork, title, artist, year, the kind of record it is (album,
EP, live, compilation), and one line on why this one, now. They can play it
start to finish, ask for another, or put it on a shelf called Listen later.
That shelf is theirs to come back to; Apple Music has nothing like it.

An album is the one listening unit the DJ cannot build but can choose. It
needs no sequencing and no outside-picks cap, which makes it cheaper than a
mix, and it is the natural shape for "something new".

## Vocabulary

Talking to the DJ in Album mode creates an **album pick**. An album pick can
be **played now** (the album is queued in Apple Music) or **saved for later**
(it joins the listener's **Listen later** shelf). "Create as playlist" does
not apply to an album. The 2026-08-30 terminology for mixes is unchanged.

## What exists, and what does not

- The DJ loop, session tables, Haiku titles, memory notes, familiarity and
  the Apple catalogue client all exist and are reused.
- There is no album object. `tracks.album` is a free-text name; library sync
  stores the same string per song. No album id, no UPC, no album artwork, no
  per-listener album affinity. The mix pool, embeddings and features are all
  per track, so the mix engine cannot be pointed at albums as it stands.
- The Apple catalogue client searches and fetches songs only. The catalogue
  also serves albums (search with `types=albums`, and `albums/{id}` with UPC,
  track count, release date, artwork, `isSingle`, `isCompilation`); the
  client gains those two calls.
- The iOS bridge queues songs by Apple ID through the system player and the
  app-owned player; web does the same through MusicKit JS. Both players can
  take an album by id, so play-now is a small extension, not new playback.

## The composer

- The app-wide segmented control (decision 2026-09-18) holds **Mix | Album**
  in the composer: on web beside the Shape control, on native in the Home
  panel. It is a mode, not a setting: it changes what the DJ returns, so it
  is never remembered across launches. Mix is the default.
- With Album selected, Shape is hidden. An energy arc has no meaning for a
  fixed sequence, and the request carries no `energyArc`.
- If the prompt itself asks for an album ("an album for the train home"),
  the composer switches the control to Album visibly before send. It never
  infers the mode silently, so the listener always sees what they are about
  to get. The nudge is a client-side word match, not a model call.
- Home's idea pills change with the mode (at most three, as today).
- The playlist inspiration attachment is allowed in Album mode: a playlist
  profile is a fine description of what to look for.
- Anonymous listeners never see the control (decision 2026-10-20: mixes
  only before an account).

## Candidates

Two sources, blended by the familiarity dial the DJ already sets per brief.

**From the shelf.** Albums the listener plainly owns. Group the listener's
candidate rows (the same rule the mix pool uses: library, seeds, counted
plays) by artist and album name, keep groups of at least four songs, and
score each by the mean meaning similarity of its songs to the brief, with a
play-count and recency term. The top ten are listed to the model as "on
their shelf", each with its song count and plays. Grouping by name is
honest about what we hold; the catalogue step below turns the chosen name
into a real album with an id.

**From the catalogue.** For new-to-them albums the model proposes. Sonnet
knows albums well in a way it does not know deep cuts, so it names three to
five candidates for the brief with artist, title, approximate year, the type
it believes the record is, and one line of why. The server then verifies
each against the Apple catalogue: an album search in the listener's market
(default storefront as a fallback, as linking does), matched on artist and
title, singles dropped unless the brief asks for one. Anything the catalogue
cannot confirm is discarded. The catalogue check is the hallucination
guard; the model never gets to show the listener an album we could not find.

**Familiarity.**

| Familiarity | Where the pick comes from |
|---|---|
| comfort | the shelf only; the model must choose from the listing |
| mix (default) | either; shelf and catalogue candidates ranked together |
| adventurous | the catalogue, unless nothing verifies |

**Ranking** after verification, in code: brief fit (the model's own order,
plus shelf similarity where it exists), artist affinity (the listener holds
other songs by the artist: the safest new pick, as in outside picks), and a
penalty for anything already on Listen later or passed over in this
session. The first is the pick; the next two are runners-up. A listener's
own shelf album is never labelled new to them; a catalogue album whose
songs they hold none of is.

**Type.** The model labels the record (album, EP, live, compilation,
soundtrack, mixtape). Apple's `isSingle` and `isCompilation` override the
label when they disagree; otherwise the model's word stands. The label is
shown on the card and stored with the album.

## The conversation

An album session is a `dj_sessions` row with `kind = 'album'`, so transcript,
title, rename, archive, memory notes and the Mixes list come free. Its loop
is its own bounded loop (the pattern of playlist editing), with tools
`recommend_album`, `remember_preference` and `rename_session`, and none of
the queue tools. The server runs the verify-and-rank step inside the tool,
hands the verified list back as the tool result, and the model writes the
reply in words (no em dashes, as for mixes).

Refinement is the same conversation: "another", "older", "same artist but
earlier", "something I don't know". Each turn that changes the pick writes
a new pick version; the earlier pick is kept and shown as passed over, so
"go back to the first one" works and the pass is a taste signal.

Honest failures: a brief that verifies nothing gets the DJ's plain reply,
not an invented album; comfort with an empty shelf gets the same honest
message the mix path uses for an empty library.

## The album card

Shown in the conversation in place of the mix panel: artwork, title, artist,
year, type label, track count and length, the "why" line, and a "new to
you" mark when it applies (the approved 2026-10-03 mark). Runners-up sit
collapsed under it as two small rows. Actions:

- **Play now.** iOS queues the album in Apple Music through the existing
  bridge, extended to accept an album id, on whichever player the listener's
  playback setting selects. Web sets the MusicKit queue to the album.
- **Listen later.** A toggle; saving and unsaving are both one tap.
- **Spotify-only listeners** see an "Open in Spotify" link that opens a
  Spotify search for artist and title, since we hold no Spotify album ids
  and their API is closed to us. Verification still runs against the Apple
  catalogue, which is ours to call for any listener.
- "Make a mix around this album" is deliberately not in this round (see
  Non-goals); it is the obvious bridge back to the core product once album
  picks have run.

## Listen later

- A user-scoped shelf. Saving records the album, the session it came from
  and when. Removing is soft (kept for the taste signal, hidden from the
  shelf). Re-saving a removed album revives the same row.
- It lives in the Mixes tab on native and the Mixes view on web, as a
  section or filter beside mixes, because it is a DJ output. Rows are
  flush, artwork left, title and artist, the type label, and the "why" line
  on expand; swipe to remove with Undo in the house style. Tapping a row
  opens its album session, where play-now and refinement already live.
- Listened: a row gains a listened date when the listener marks it, or,
  once app-owned playback evidence exists for albums, when the evidence
  shows more than half the album's songs played in one sitting. The second
  path is phase 3 and evidence-gated; phase 1 ships the manual mark only.
  Listened rows move below the unlistened ones, not off the shelf.
- It stays in-app. Nothing is written to the Apple Music library by saving.

## Taste signal

Saving is a strong positive signal, passing over a pick a negative one,
marking listened a positive one. Phase 1 records them as session events;
nothing is weighted yet. Feeding them into the learned artist term is a
follow-up with evidence, as the outside-picks caps were.

## Data

Keyed platform-agnostically, as tracks are: internal id plus UPC, with
`apple_id` one column among future peers.

- `albums`: id, upc, apple_id, apple_catalog_storefront, title, artist,
  release_year, track_count, duration_ms, type, artwork fields as on
  `tracks`, created_at. Unique on apple_id where not null, index on upc.
- `dj_sessions.kind`: `'mix' | 'album'`, default mix. Mix routes refuse an
  album session and the album route refuses a mix session.
- `album_picks`: id, session_id, version, rank (0 is the pick), album_id,
  reason, new_to_them, created_at. The latest version's rank 0 is the
  current pick; earlier versions are the passed-over history.
- `listen_later`: user_id, album_id, session_id (nullable), saved_at,
  listened_at (nullable), removed_at (nullable). Primary key user and album.
- The anonymous merge rule (decision 2026-10-20) needs no change: album
  sessions move with `dj_sessions`, and Listen later rows move with the
  listener's other user-scoped rows. Album mode is not offered before
  sign-in, so in practice there is nothing to move.

## API

- `POST /sessions` gains `kind` (default `mix`). An album session's first
  turn and `POST /sessions/:id/messages` run the album loop. The session
  read returns `pick`, `runnersUp` and `passed` instead of a queue.
- `GET /me/listen-later`, `PUT /me/listen-later/:albumId`,
  `DELETE /me/listen-later/:albumId`, `POST /me/listen-later/:albumId/listened`.
- Behind a server flag `ALBUM_PICKS` that defaults off, as outside picks
  were, so the server lands before the clients.

## Cost

Per album turn: one Sonnet call with a tool and its continuation (the same
shape as a mix turn), one brief embedding for shelf ranking (as today), and
at most six Apple catalogue calls (five searches, one album fetch). No pool
listing of hundreds of lines, so fewer input tokens than a mix. Well inside
the 50-subrequest budget of a turn. Nothing new runs on the cron.

## Tests

Golden-set structural assertions, never exact-album assertions.

- A pick is never returned without a verified catalogue album; the model's
  unverifiable proposals are dropped; a brief that verifies nothing yields
  the honest reply.
- comfort yields a shelf album only, or the honest empty message; adventurous
  yields a catalogue album whenever any verified non-shelf candidate exists.
- The type label comes from the model and is overridden by Apple's single
  and compilation flags.
- A shelf album is never marked new to them; an album with no held songs is.
- Passed-over albums and Listen later albums rank below fresh candidates in
  the same session.
- Listen later save, unsave, re-save and listened are idempotent; removed
  rows never show on the shelf; the shelf is keyed by user.
- Spotify-only listeners get the search link and no Apple play action.
- Composer: Shape is hidden in Album mode and no `energyArc` is sent; an
  "album" prompt flips the control before send and never without showing it;
  the control is absent for anonymous listeners.
- Mix routes refuse album sessions and the reverse.

## Build order

1. Server: catalogue album calls, schema and migration, the album loop and
   routes, Listen later routes, all behind `ALBUM_PICKS` off.
2. State board: composer control (web and native), album card with actions,
   runners-up, passed-over history, Listen later shelf in Mixes, empty and
   failure states. Founder approval.
3. Web client.
4. iOS client, including the bridge extension for album playback.
5. Flag on; three founder briefs (comfort, default, adventurous), one on a
   Spotify-only account.
6. Later, evidence-gated: listened-from-playback, taste weighting of saves
   and passes, "make a mix around this album".

## Decisions taken (founder, 2026-10-20)

1. **Spotify-only listeners** get album picks with an "Open in Spotify"
   search link only. Accepted for now.
2. **Both sources ship together**, shelf and catalogue, blended by
   familiarity. Shelf-only would feel thin; catalogue-only would ignore the
   taste graph.
3. **Record type**: the model picks and labels it; Apple's flags override.
4. **Listen later stays in-app**; nothing is written to Apple Music.

Recommended with the direction, not separately decided: one pick with two
runners-up rather than a list; the control is visible with a prompt nudge
rather than inferred; the shelf lives in Mixes; albums stay out of the
first run.

## Non-goals

A corpus of album embeddings, Apple's recommendation endpoints, album picks
for anonymous listeners, "make a mix around this album", writing Listen
later to Apple Music, Spotify album ids, auto-listened from playback in
phase 1, and any change to how mixes are made.

## Reopens if

Verification discards most of the model's proposals (then the catalogue
search needs a looser match or an artist-albums lookup), album picks are
passed over far more often than played or saved (then the ranking or the
candidate count changes), Spotify-only listeners use the feature enough
that a search link is not good enough, or Listen later fills faster than it
empties (then the shelf needs ordering and a listened path from playback
sooner).

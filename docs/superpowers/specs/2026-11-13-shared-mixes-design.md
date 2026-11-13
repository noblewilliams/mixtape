# Shared mixes

Date: 2026-11-13. Status: approved direction (founder, 2026-11-13), board pending.

## Why

A user asked to send a mix to a friend so the friend can listen to it. Today a
mix only exists inside its owner's account. The nearest thing is "Create
playlist" followed by sharing the Apple Music or Spotify playlist, which loses
Mixtape entirely and needs the sender's own service.

## What it is

A mix gets a link. Someone who opens the link sees that mix as the sender made
it, with the sender's first name, and can play it. That is the whole feature:
the recipient cannot prompt, edit, reorder or remix it.

- **Recipient has the app:** the link opens the app (iOS universal link) on a
  read-only view of the mix, and the mix joins their Mixes marked "From Ada".
- **Recipient has no app:** the link opens a public web page with the mix.
  No sign-in is needed to look at it. Play asks "Where do you listen?"
  (Apple Music or Spotify) and then does what the web app already does.

## Decisions

1. **The link is a snapshot.** Sharing records the mix as it stands: its
   title, tape colour and ordered songs at the current `queue_version`. Later
   turns or edits by the sender do not change what the link shows. Sharing
   again after an edit gives a new link; sharing again without an edit
   returns the same link. Snapshot rows are copied into the share (not
   referenced through `mix_versions`), so nothing in mix history can change a
   share after the fact.
2. **The recipient sees title, tape colour, artwork, songs and the sender's
   first name only.** Never the conversation, the prompt, the DJ's per-song
   reasons or the energy shape. Prompts are often private.
3. **A share needs a name.** If the sender's name is not usable
   (`isUsableName` is false, anonymous listeners included), Share first shows
   the existing "What should we call you?" page; the answer is saved as the
   profile name and the share continues. Skip is not offered on this path:
   the page explains the name is shown to whoever opens the link. Only the
   first word of the name is shown to recipients.
4. **Links are random tokens and can be turned off.** The URL is
   `https://miixtape.netlify.app/m/<token>` with a 22-character base62 random
   token (about 131 bits), never the session id. "Stop sharing" in the mix's
   menu revokes every link for that mix. A revoked or unknown token shows "This
   mix isn't shared anymore." Deleting the mix or the account deletes its
   shares (cascade).
5. **Mixes only.** Album sessions (`kind = 'album'`) have no Share in v1.
6. **Link previews are in scope.** iMessage, WhatsApp and the rest read Open
   Graph tags, which the single-page app cannot set per mix. A Netlify edge
   function on `/m/*` reads the public share endpoint and writes `og:title`
   ("Ada shared a mix"), `og:description` (the mix title and song count) and
   `og:image` (the first song's artwork at 600×600, or the tape-colour card
   when no song has artwork) into the app's HTML. If the API fails, the
   function returns the HTML unchanged.
7. **Domain stays `miixtape.netlify.app`.** Universal links and the
   association file live there. Moving to a custom domain later means keeping
   this site up (or redirecting `/m/*`) for links already sent.
8. **A saved share is not a copy.** The recipient's Mixes shows a reference
   to the share, never a `dj_sessions` row. Nothing on the server lets a
   non-owner change it, so read-only holds by construction.
9. **Out of v1:** opening the mix after an install from a link (deferred deep
   links), view counts for the sender, remixing or prompting a shared mix,
   sharing albums, matching songs to the recipient's country store.

## Behaviour

### Sender

- **Share** appears on a mix that has at least one active song: on iOS in the
  conversation strip's menu and the arrangement bar's menu; on web in the
  mix's tape actions. It is not a third bar button (the bar's actions are fixed
  per decision 3 of 2026-11-09 one-platform-play).
- Tap Share → (name page if needed) → `POST /sessions/:id/share` → system
  share sheet with the link and the text "Listen to my mix “<title>” on
  Mixtape". On web, `navigator.share` when available, otherwise copy the link
  and show the toast "Link copied".
- **Stop sharing** appears in the same menu only while the mix has an active
  share. It confirms with "People with the link won't be able to open it."
  and calls `DELETE /sessions/:id/share`.
- The sender opening their own link goes to their own mix, as normal.

### Recipient in the app (iOS)

- The universal link opens the app at `SharedMixScreen(token)`. It loads
  `GET /shared/:token` without needing a session, so it works on a fresh
  install that has not been through first run yet.
- The screen shows the cassette in the share's tape colour, the title,
  "From Ada", the song rows and the mix actions for the listener's platform
  exactly as on their own mixes: Apple Music → **Play** / **Create
  playlist**; Spotify → **Create playlist** (TuneMyMusic handoff). If the
  platform is unknown, the existing "Where do you listen?" sheet opens on the
  first action. There is no composer, no swipe-to-remove on rows, no rename
  and no history.
- If the listener has a session (account or anonymous), the share is saved to
  their Mixes (`POST /shared/:token/save`, idempotent). A listener with no
  session yet sees the mix and can play it. The save happens once a session
  exists (after first run creates one), from a pending token kept on the
  device.
- In Mixes, the shared mix is a normal row with the subtitle "From Ada" in
  place of the song-count line's first part. Tapping it opens
  `SharedMixScreen`. The swipe action is **Remove** (deletes the save, not the
  share). Shared rows sort with the listener's own mixes by the time they
  were saved. They are not counted against the anonymous three-mix cap.
- A revoked share disappears from Mixes on the next list read. If it is open,
  the screen shows "This mix isn't shared anymore." with a Remove button.

### Recipient on the web

- `/m/<token>` serves the web app, which renders `SharedMixPage` outside
  `AuthGate` (no sign-in, no first run).
- The page shows the cassette, title, "Shared by Ada", the songs, a **Play**
  button, **Get the app** (the existing install/download destination) and
  **Make your own mix** (opens `/app/` into first run).
- **Play** opens a modal titled "Where do you listen?" with Apple Music and
  Spotify, unless `plays-on` already holds an answer, which it then uses. The
  answer is written to `plays-on`.
  - **Apple Music:** creates an anonymous session if the browser has none
    (`ensureSession`; the MusicKit developer token requires a session),
    authorizes MusicKit JS and plays the songs that have Apple ids, in order,
    through the existing web playback controller. Songs without an Apple id are
    skipped silently, as in the web app today.
  - **Spotify:** the existing TuneMyMusic handoff with this mix's songs,
    including the first-time explainer.
- A browser that has a session (signed in or anonymous) saves the share to its
  Mixes on open. The web Mixes view shows shared rows the same way iOS does.

### Merging and deletion

- Anonymous-to-account linking (`link-anonymous.ts`) moves saves to the
  account, skipping a save the account already has, and moves shares with the
  sessions they belong to.
- Account deletion cascades shares (through sessions) and saves (through the
  user).

## Data

Two tables, one migration:

```
mix_shares
  id            uuid pk
  token         text unique not null           -- 22-char base62
  session_id    uuid not null → dj_sessions.id on delete cascade
  sharer_id     text not null → user.id on delete cascade
  queue_version integer not null
  title         text not null                  -- copied at share time
  case_color    text not null
  entries       jsonb not null                 -- [{ position, trackId }], active songs in order
  created_at    timestamptz not null default now()
  revoked_at    timestamptz
  index (session_id, queue_version) where revoked_at is null

mix_share_saves
  user_id    text not null → user.id on delete cascade
  share_id   uuid not null → mix_shares.id on delete cascade
  saved_at   timestamptz not null default now()
  primary key (user_id, share_id)
```

The sender's name is read live from `user.name` (first word), so a rename
shows on links already sent. Song metadata is read live from `tracks`
(shared catalogue rows), so artwork found later shows too.

## API

| Method | Path | Session | Result |
|---|---|---|---|
| POST | `/sessions/:id/share` | owner | `{ token, url }`. Reuses the active share at the current `queue_version`, else creates one. 409 `name_required` when the name is not usable; 422 `empty_mix` with no active songs; 404 for album sessions and non-owners. |
| DELETE | `/sessions/:id/share` | owner | 204. Revokes every active share of the mix. |
| GET | `/sessions/:id` | owner | adds `shared: boolean` (an active share exists) for the menu. |
| GET | `/shared/:token` | none | `{ token, title, caseColor, sharerName, sharedAt, isOwner, sessionId?, tracks: [{ title, artist, album, durationMs, artwork, appleId, isrc }] }`. `isOwner` and `sessionId` only when a valid session belongs to the sharer. 404 unknown, 410 revoked. Rate-limited per IP. |
| POST | `/shared/:token/save` | any | 204, idempotent. 204 and no row when the caller owns the share. 404/410 as above. |
| DELETE | `/shared/:token/save` | any | 204. |
| GET | `/me/shared-mixes` | any | `{ mixes: [{ token, title, caseColor, sharerName, savedAt, trackCount, durationMs, artwork }] }`, active shares only, newest save first. |

`/shared/*` reads the session if one is present but never requires it.
CORS allows the web origin as for the other routes.

## Platform pieces

- **Association file:** `/.well-known/apple-app-site-association` (served as
  `application/json`, no redirect) with `applinks` for the app id
  `<TeamID>.<bundle id>` and the component `/m/*`. Written by
  `scripts/build-site.mjs`; `_redirects` gains `/m/* /app/index.html 200`
  before the catch-all.
- **iOS:** the Associated Domains capability on the App ID (Apple Developer
  portal, founder), `com.apple.developer.associated-domains` =
  `applinks:miixtape.netlify.app` in `Runner.entitlements` (already in the
  target), and the `app_links` package for the incoming-link stream
  (cold start and running). Universal links need a device check on a
  TestFlight build: the simulator does not prove them.
- **Edge function:** `netlify/edge-functions/shared-mix-og.ts` on `/m/*`.

## Known limits

- Apple song ids are tied to a country store. A recipient in another country
  may find some songs unplayable in Apple Music. Not fixed in v1.
- A recipient on the web who chooses Apple Music gets an anonymous account
  (needed for the MusicKit token). It follows the existing anonymous
  retention (30 days).
- A link opened on a device without the app installed always goes to the web
  page; installing the app afterwards does not open that mix.

## Reopens if

- Senders ask to update a link after editing (then: a live link option).
- Recipients ask to remix a shared mix (then: "Make it mine" copies the share
  into a new session they own).

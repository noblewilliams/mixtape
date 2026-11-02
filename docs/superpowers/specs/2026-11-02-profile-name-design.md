# Profile name — design

Status: draft 2026-11-02. Decisions taken by the founder the same day (see
`../../decisions.md` → 2026-11-02 profile name). Board pending:
`../../mockups/2026-11-02-profile-name-states.html`.

## Why

A listener's name is Better Auth's `user.name`. Today it is only ever set by
the sign-in provider, and only Google reliably sets it:

- iOS asks Apple for `fullName` (`client/lib/data/auth/apple_auth_gateway.dart`)
  but sends only the identity token, so the name Apple discloses once, at the
  first-ever sign-in, is thrown away. Apple ID tokens never carry the name.
- Anonymous listeners are named `Listener` by the anonymous plugin.
- Nothing lets a listener set or change their name. The founder's own was set
  by SQL.

Where it shows today: the identity row on iOS Account and You
(`Your account` when blank), web Settings › Account, and the author default in
the iOS create-playlist dialog (`mix_handoff.dart`, after the device-stored
author). Blends and taste twins (2026-09-09 spec, section 6) will show a chosen
display name, so this is their prerequisite.

## Decisions

1. **Keep the provider's name.** iOS passes Apple's `givenName` / `familyName`
   to the server with the identity token as Better Auth's
   `idToken.user.name.{firstName,lastName}`, which it already uses when it
   creates the user. Google is unchanged. Web Apple redirect sign-in needs no
   change: Better Auth 1.7.2's callback parses the `user` form field Apple
   posts on the first sign-in and the Apple provider builds the name from it.
2. **Ask if missing.** After a sign-in, a listener whose account has no usable
   name sees one optional first-run-style page, "What should we call you?",
   with one field, Continue and Skip. Shown once per account: Continue or Skip
   both record that it was asked, so it never returns, on any device.
   Existing signed-in accounts with no name see it once on their next launch.
   Never shown to anonymous listeners.
3. **Edit in Account only.** iOS: the identity row at the top of Account
   becomes editable. Web: the name in Settings › Account becomes editable.
   Hidden for anonymous listeners (they have no Account or Account section
   today). The save-playlist author field stays separate.
4. **The DJ may use the first name, sparingly.** The mix and album DJ prompts
   receive the listener's first name, with an instruction to use it rarely: at
   most once in a conversation, never as a greeting on every turn.

## Rules

- **Usable name:** after trimming and collapsing inner whitespace, 1 to 40
  characters, no control characters. `Listener` (the anonymous default) counts
  as missing. Blank clears the name back to `Your account`.
- **Server is authoritative.** Better Auth's `/update-user` already accepts
  `name` with a bearer session; a `databaseHooks.user` create/update hook
  normalises and caps every write (provider, prompt page, Account), so no
  client can store an unbounded or control-character name.
- **"Asked" flag:** a nullable user field (e.g. `namePromptedAt`), writable
  by the owner through `/update-user`, reported by `GET /me`. The prompt shows
  when the name is not usable and the flag is null. Saving a name from Account
  also sets it.
- **Anonymous link:** the account created on link takes the provider's name
  (decision 1); if none, the prompt follows the sign-in.
- **DJ:** first name is the first whitespace-separated word, passed through
  `sanitizeForPrompt` and capped at 20 characters, rendered as data the same
  way memory notes are, never as an instruction. No name, no line.
- **Account deletion** already removes the user row; nothing extra.

## Surfaces (board covers)

- First-run page "What should we call you?": empty, typing, saving, save
  failed (field and text kept, Retry), large text. iOS and web, light and dark
  (first-run pages are identical in both themes). Background: one of the
  existing first-run images; the board proposes which.
- iOS Account identity row: named, unnamed, editing, saving, failed, cleared.
- Web Settings › Account: same states, inline edit.
- Comparison: today's unnamed Account and Settings rows.

## Out of scope

The DJ writing the name; a separate display name for social features (the
same field serves until blends need more); avatars; changing the playlist
author dialog.

## Tests

Server: provider name stored on Apple ID-token sign-in; normalisation and cap
on create and update; `Listener` treated as missing; `GET /me` reports the
flag; first name in the DJ prompt only when usable, sanitised. Web and iOS:
the prompt shows once and never for anonymous listeners; Continue and Skip
both set the flag; Account edit saves, fails and retries, and clears.

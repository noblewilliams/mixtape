# Approved profile name

Approved November 2, 2026: founder replied "Approve as recommended" to
[profile name states](../2026-11-02-profile-name-states.html). Spec:
`../../superpowers/specs/2026-11-02-profile-name-design.md`. Decisions:
`../../decisions.md` → 2026-11-02 profile name.

## Winning direction

Every recommendation on the board's "Decisions for you" list:

- **Name page** ("What should we call you?") on the plum sign-in background,
  first-run grammar: headline, one line, the field, the Continue pill, and a
  quiet foot link "Skip". No back button. No autofocus: one tap raises the
  keyboard. Shown once per account after a sign-in that leaves no usable name
  (blank or `Listener`), and once on next launch for existing accounts in that
  state; Continue and Skip both record that it was asked.
- **iOS Account:** the identity row is the button, with a trailing text
  action "Edit" or "Add name" (no pencil, no chevron). Editing is inline: the
  row title becomes the field, Save and Cancel sit under the group as text
  actions, as in `mix_name_editor.dart`.
- **Web Settings › Account:** an "Edit name" ("Add name" when unnamed) text
  button before "Manage account". Inline field, 14 px, Save and Cancel; Enter
  saves, Escape cancels. Focus shows as the underline thickening to 2 px slate.
- **Unnamed** reads "Your account" on both platforms.

Rejected: violet background (belongs to path A, which these listeners may have
just seen); magenta (reads as starting over); Skip as a second pill (louder
than an optional question); autofocus (reads as a demand, hides the image); a
native alert with a field on iOS (hides the screen, cannot show a failure
without closing).

## Locked behaviour

- Copy: "What should we call you?"; iOS line "It shows in Account, and the DJ
  may use it now and then."; web line "It shows in Settings, and the DJ may
  use it now and then."; field "Your name"; Continue; Skip; Saving; "Couldn’t
  save your name."; Retry; Edit; Add name; Edit name; Save; Cancel; hint "Up to
  40 characters. Leave it blank to remove your name."; "Names stop at 40
  characters."; count "34 of 40". No em dashes.
- 40 characters is a hard stop; the count appears from 30; a longer paste is
  cut with "Names stop at 40 characters." The server caps again.
- Saving blank clears the name without confirmation.
- Save failure keeps the typed text and offers Retry beside the field.
- Announcements: "Name saved", "Name removed", "Couldn’t save your name."
- Name page field is 16 px on web (as the other first-run fields); the
  Settings field is 14 px. iOS keyboard on the name page is dark.
- Disabled Continue keeps focus with `aria-disabled` on web.
- Targets: 44 pt iOS, 44 px web on coarse pointers.

## Open questions, resolved by default

- If Skip's flag write fails, the app moves on and retries the flag on the
  next launch (the page may show once more on that device).
- The page appears straight after the Keep this mix sign-in.

## Not resolved here

The avatar shape mismatch (You circle, Account square without an initial),
`.wc-text` height and `.setting-row small` contrast on web are existing
drift, out of scope.

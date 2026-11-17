# Approved select and delete mixes

Approved November 16, 2026: the founder replied "Approve defaults" to the
[board](../2026-11-16-select-delete-mixes.html). Server route
`POST /sessions/delete` (`server/src/routes/sessions.ts`) was written before
the board; decision in `docs/decisions.md` (2026-11-16, mixes can be deleted).

## Open questions, settled as the board's defaults

1. **Way in on iOS:** a small glass ⋯ circle in the Mixes nav bar whose
   anchored popover holds *Select mixes*, plus *Select* in each row's menu
   (long-press, or More on swipe), which opens select mode with that row
   ticked. The Archived screen gets the same ⋯.
2. **Shared mixes** ("From Ada") are dimmed and take no circle or checkbox in
   select mode. They keep their own Remove.
3. **Delete lives only in select mode.** The row menu and swipe are unchanged
   apart from the added *Select* item.
4. **Signed-out (anonymous) listeners can't delete.** Delete stays visible and
   opens "Sign in to delete mixes"; the server refuses with
   `403 { error: 'sign_in_required' }`.

## Locked behaviour

- iOS select mode: a circle at each own row's leading edge (filled plum with a
  check when ticked; light plum with a dark check in dark mode); tap ticks, swipe
  and long-press are off; nav bar shows *Select all* / *Deselect all* (glass
  pill, leading) and a ✓ glass circle (Done, trailing); the large title stays.
  The dock (tab bar and mini-player) gives way to one glass toolbar:
  Archive (box glyph) · "N selected" · Delete (eject glyph, destructive red).
  Archive and Delete are disabled at zero. The segmented Active | Listen later
  control hides while selecting; Listen later has no select mode. On Archived,
  Unarchive replaces Archive.
- Confirm: an anchored glass popover over Delete (not an action sheet).
  "Delete 2 mixes?" / "Delete this mix?" — "They're gone for good, with their
  chats and versions. This can't be undone." plus "Their share links will stop
  working." when a ticked mix is shared, and "The one being made will stop."
  when a ticked mix is working. Buttons "Delete 2 mixes" / "Delete mix"
  (destructive) and "Cancel". Archive asks nothing.
- While deleting, ticked rows fade; the toolbar stays. Success: rows leave,
  select mode ends, the dock returns, toast "2 mixes deleted" / "Mix deleted".
  No Undo. Failure: rows return, selection kept, alert toast
  "Couldn't delete. Try again."
- Anonymous: popover "Sign in to delete mixes" — "Mixes made before you sign in
  can be archived, not deleted." — "Sign in" · "Not now".
- Largest text: titles wrap, circle top-aligned; toolbar labels cap like the
  segmented control and the count drops first. Whole row is the tick target.
  VoiceOver: row "Title, subtitle, selected"; count changes announced.
- Web: a quiet *Select* text button beside the view switch (becomes *Done*) in
  List and Grid; hidden in Closet. Real checkboxes labelled by mix title; a row
  click ticks instead of opening; Shift-click ticks a range; Escape leaves.
  Count line reads "2 of 5 selected". A small floating bar: "N selected" ·
  Archive · Delete. Confirm is the existing `ControlModal` (alert) with the iOS
  copy, Cancel focused first, error shown inside the modal. Success: status
  toast "2 mixes deleted". Anonymous: modal uses the sign-in copy with a
  Sign in button.

## Not drawn

The Grid-view checkbox (top-left of each tile) and the row-menu *Select*
item. Build them with existing pieces.

## Expected owners

- iOS: `client/lib/presentation/screens/mixes_screen.dart`,
  `archived_mixes_screen.dart`, `widgets/mix_home_row.dart`, dj providers and
  API client under `client/lib/data/dj/`.
- Web: `web/src/components/Home.tsx`, `SessionControls.tsx`, `web/src/App.tsx`
  and the API module.

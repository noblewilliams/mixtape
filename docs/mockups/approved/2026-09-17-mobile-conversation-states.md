# Approved native conversation states

Approved September 17, 2026: founder replied "approved" to
[conversation states revision 1](../2026-09-17-mobile-conversation-states.html).
Extends the [shell approval](2026-09-17-mobile-shell.md), which locks the
frame: glass back and action clusters, small title, flush turns, bottom panel
with attachments, composer and mix actions, tab bar hidden.

## Locked behaviour

- The latest reply whose arrangement is current carries the tape card:
  cassette, song count, duration, version, and Open into the arrangement.
  Earlier arrangements are "Version n" chips (renamed from "queue updated ·
  vN") that open history at that version. An energy line under the card
  states the assessed shape against the ask, including "limited coverage".
- DJ bubbles have no accent bar. User turns are tape-coloured on the right.
- Working: three static-capable dots at once; the "the DJ is listening…"
  caption after a delay; composer, attachments and mix actions disabled in
  place. Status region announces "The DJ is working".
- Clarifications are ordinary DJ turns answered in the composer. With no
  arrangement, no tape card and disabled mix actions.
- "Not personal yet" shows under the title with one explanatory line for a
  Spotify listener before import.
- Failed turn: an error turn under the message it answers with Resend of that
  text; disabled while another send or arrangement edit is in flight. The
  previous arrangement stays live. Seeded from Home when the first turn failed
  after the mix row was created.
- Opening: chrome present from the first frame; skeleton turns only.
  Could-not-open only when nothing is on screen; a failed refresh of a visible
  transcript is a brief toast.
- Energy shape sheet from the Shape chip: Steady, Build gradually, Wind down,
  Build, then settle, with the shipped copy; Use this shape writes an editable
  sentence and toasts "Shape added to your brief. Send when ready."; the
  too-long brief message is shown in the sheet.
- Attachment chips: unavailable keeps the name and offers Replace and Detach;
  too few matched songs cannot be sent; a selection changed elsewhere refreshes
  to canonical, preserves arrangement and unsent text, and toasts.
- More menu: Version history, Rename (native alert, title preselected),
  Archive or Restore. Archive toasts "Mix archived" with Undo and leaves the
  conversation open.
- Keyboard raises the panel; reduced motion makes dots static and removes
  slides; reduced transparency makes panel, clusters and toast opaque.

## Owners

`client/lib/presentation/screens/chat_screen.dart`,
`client/lib/presentation/widgets/{queue_card,mix_energy_summary,
energy_journey,playlist_inspiration}.dart`.

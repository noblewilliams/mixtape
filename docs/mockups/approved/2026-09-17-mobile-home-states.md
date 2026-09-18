# Approved native Home states

Approved September 17, 2026: founder replied "approved" to
[Home states revision 1](../2026-09-17-mobile-home-states.html). Extends the
[shell approval](2026-09-17-mobile-shell.md); the base Home layout is locked
there.

## Locked behaviour

- Typing: the bottom panel rides up on the keyboard and the dock sits behind
  it. Pills dim once the field has text; tapping one replaces the text with an
  undoable swap. Send lights only with text.
- Playlist attached: a label chip above the composer names the exact playlist
  and offers Replace, Exclude its songs, Detach. Placeholder and pills become
  refinements of that playlist. Nothing sends until Send.
- Picker: a sheet over Home with search, exact playlist identities and source
  labels, pagination on scroll, and the exclude toggle. Playlists with fewer
  than three matched songs stay visible but cannot be chosen. Outside tap, Back
  or the handle dismiss without changing the attachment.
- Starting: the cassette hubs turn in the open space with "Making your mix"
  and a duration hint; the composer locks with the prompt visible; the
  conversation is pushed when the server answers. Reduced motion: hubs still,
  text carries the state; announced as "Making your mix".
- Start failed: an alert line under the composer with the offline or server
  copy; prompt kept; Send live again. If the mix row was created before the
  turn failed, Home opens the conversation and the retry lives there.
- Spotify listener before imports land: two flush rows in the open space
  (import status with elapsed wait; interview until done) opening the existing
  screens, plus the "Not personal yet" note. Rows disappear when both packages
  land. No routine pill without history.
- Pills: starter pills show at once; only the routine slot is a skeleton while
  loading and fills with a third starter prompt when nothing is eligible.
  Routine pills have a native context menu: Not today, Why this?, Turn off
  routine suggestions (same toggle as You). Starter pills have no menu.
  VoiceOver exposes the same actions as rotor actions.
- Voice (planned before launch): mic becomes Stop; the field shows a prism
  level meter and "Listening…"; the transcript lands in the field for editing
  and never sends by itself. Permission denied uses the failure line with
  Settings guidance.

## Unresolved

- Pushing the conversation immediately with a working state instead of
  waiting on Home requires a server contract change and is not decided.
- Microphone copy waits on the voice feature.

## Owners

`client/lib/presentation/screens/home_screen.dart`,
`client/lib/presentation/widgets/{mix_prompt_input,playlist_inspiration,
routine_suggestions}.dart`, `client/lib/presentation/providers/
{new_mix_inspiration_provider,suggestions_provider}.dart`.

## Implementation departures

- 2026-09-18, Phase 3: the routine pill's long-press menu is a Material
  anchored menu and "Why this?" a bottom sheet, not a native context menu,
  because a Cupertino context menu cannot preview a pill inside the glass
  panel. The three actions and their custom semantics actions match the record.
- 2026-09-18, Phase 3.3: the picker marks a playlist "Not enough" when it has
  fewer than three entries in total, because the summary carries no matched
  count (the board shows "2 matched songs · too few to use"); at 200% text the
  picker sheet drops its title and the exclude row's subtitle so the toggle
  stays reachable; the waiting rows carry a "Choose files" chip that frame S3
  does not draw, keeping the import entry reachable from Home.

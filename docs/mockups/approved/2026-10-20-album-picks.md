# Album picks and Listen later

Approved by the founder 2026-10-20 ("Approved as drawn") after one revision
round (compact composer controls). Board:
`../2026-10-20-album-picks-states.html` (revision 1 with the compact
controls). Spec: `../../superpowers/specs/2026-10-20-album-picks-design.md`.
Plan: `../../superpowers/plans/2026-10-20-album-picks.md`. Decision:
`../../decisions.md` 2026-10-20. Nothing is built.

## Winning variant

As drawn: one pick with two runners-up; the Mix | Album control visible in
the composer with a prompt nudge; the Listen later shelf inside Mixes;
albums absent before an account.

## Rejected alternatives

- A list of three albums instead of one pick: loses the decision the DJ is
  meant to make; the runners-up carry the choice.
- Listen later as its own shell tab: a fifth tab for a shelf most sessions
  will not touch.
- Inferring Album from the prompt silently: the listener would not know what
  they were about to get.
- The first revision's 30 to 36 pt composer controls: the founder asked for
  compact; 26 pt drawn with a 44 pt hit area won.

## Locked behaviour

**Composer, native (H1 to H4).** The app-wide segmented control holds Mix |
Album on a compact row above the composer, leading edge, with the Shape chip
trailing. Both are 26 pt tall drawn with 11.5 pt labels and a 44 pt invisible
hit area (28 to 32 pt at 1.5x text). Mix is the default; the mode resets on
every launch and is never a remembered setting. Under Album the Shape chip is
absent, no `energyArc` is sent, the placeholder reads "What kind of record
are you in the mood for…", Send is named "Find an album", and the three
starter pills become album asks. A prompt containing the word "album" with
Mix selected moves the control to Album as the listener types (a 200 ms slide
of the selected segment, none under reduced motion) and shows "Switched to
Album for this prompt." with a "Keep it a mix" action under the composer,
replacing the pills until send; announced politely; a device-side word match,
never a model call. Anonymous listeners see no control; the compact Shape
chip keeps the row; their "album" prompts are sent as mixes. The playlist
attachment works in Album mode.

**Composer, web (W1, W2).** Home gains the chat composer's quiet tool row
(28 px tools, 12 px text). The control is a hairline-outlined pair with the
sidebar's quiet current fill, as the Mixes view switch is drawn, exposed as a
radio group "What to make". Shape follows it on Home for the first time and
is absent under Album. The nudge line sits where the pills were, with "Keep
it a mix" as a text link.

**Finding (A1).** The approved working dots with "Finding your album ·
checking Apple Music". No Arrangement button in the navbar for an album
session. The composer is locked until the reply lands.

**Album card, native (A2 to A8).** Flush on the conversation, no box. Cover
112 pt with a soft shadow; title; artist; meta line "{Type} · {year} · {n}
songs · {length}" with "· New to you" appended in plum weight 600 when the
listener holds none of its songs (the dot travels with the mark; the mark
never truncates). One "why" sentence in the body size. Actions: Play now as
the tape button; Listen later as a chip with the bookmark glyph. Under the
card a 44 pt "Two more it considered" row opens two 48 pt runner-up rows
with "Pick this", which swaps the pick without a model call and keeps the
old pick as passed over. A refinement writes a new pick; the earlier card
shrinks to a muted 40 pt row above the turn that replaced it, marked "Passed
over" in words, with "Go back". Saving fills the chip, changes its words to
"Saved for later", sets pressed state, and shows the compact toast "On your
Listen later shelf." with Undo for four seconds; tapping the filled chip
unsaves with no toast. Spotify-only listeners get the underlined "Open in
Spotify" text action (a Spotify search for artist and title) in place of
Play now. Dark uses the theme's inks. At 1.5x text the cover drops to 60 pt
beside the title, the meta line takes its own line and wraps, and the
actions wrap. VoiceOver reads the card as one item ending with the mark.

**Album card, web (W3 to W5).** The album panel takes the mix panel's place
at its width with the same hairline left edge and heading style ("The album
· pick n"). Cover 96 px. Play now is the panel's one filled button; Listen
later is quiet plum text with the glyph, filled and "Saved for later" when
saved. Runners-up under a hairline with Show/Hide; passed-over row in the
transcript. Below 760 px the panel folds into the conversation under the
reply that produced it, with a hairline above. No Shape tool in the chat
composer for an album session.

**Listen later, native (L1 to L3).** A third segment, "Listen later", beside
Active and Archived in Mixes. Flush rows: cover in the 60 pt tile, title,
"artist · type · year", chevron; tap opens the album session. Long-press (or
the "Show why" rotor action) expands the row with the "why" line, the prompt
it came from, and "Mark listened". Listened rows sit under a "Listened"
heading, muted, with "Listened {d Mon}" as a plum status word, and stay on
the shelf. Swipe left removes with the arrangement screen's Undo toast
("Removed from Listen later."); removal is soft on the server. Empty: the
approved cassette empty state, "Nothing saved for later", "Ask for an album,
then tap Listen later to keep it here.", one "Find an album" chip that opens
Home with Album selected.

**Listen later, web (W6, W7).** The shared Tabs component gains "Listen
later"; the view switch is absent on this tab. Count line: "4 albums saved ·
2 listened", "1 album saved", "0 albums saved". Rows use the Mixes list
metrics with a 56 px cover, the row open button, a play button and the
three-dot menu (Open, Mark listened, Remove). A "Listened" section label
precedes listened rows. Empty state centred under the toolbar with "Find an
album".

**Honest failures (F1 to F3).** Nothing verified: no card, the DJ's plain
reply with two refinement pills ("Any year", "Something stranger I do
know"). Comfort with no album group at the four-song floor: the honest
message with "Add my music" and "Something new is fine" pills. A failed turn
uses the approved error bubble with Resend and names the step that failed.

**Accessibility.** Every state is also words: "New to you", "Saved for
later", "Passed over", "Listened". Reduced motion removes the segment slide,
the runners-up height change and the passed-over shrink; the working dots do
not pulse. Row actions are rotor actions on iOS. Targets: 26 pt composer
controls and 36 pt card chips, all 44 pt effective on touch; 28 px web
tools, 44 px effective on coarse pointers.

## Intentional platform differences

Native has the segmented control; web has the outlined pair. Native expands
a shelf row by long-press; web uses the three-dot menu. Web shows a play
button on shelf rows; native plays from the album session.

## Unresolved implementation details

- Which player queues an album on iOS follows the listener's playback
  setting; the system-player path for an album id needs a device check (the
  fallback is queueing the album's song ids through the existing path).
- The exact word list for the nudge ("album" only, or also "record", "LP",
  "EP") is the implementer's call; "album" is the floor.
- The Album actions menu (Rename, Archive) is the mix menu without
  Arrangement and Version history; not drawn.

## Supersedes

The 36 pt Shape chip drawn on the 2026-09-17 Home board and the 2026-10-20
first-run board: in the composer row it is now 26 pt. The spec's "Listen
later lives in Mixes as a section or filter" is settled as a segment (native)
and a tab (web).

## Expected owners

Web: `web/src/components/PromptComposer.tsx`, `HomeComposer.tsx`, `Home.tsx`,
`HomeDashboard.tsx`, `Conversation.tsx`, new `AlbumPanel.tsx` and
`ListenLaterList.tsx`, `Tabs.tsx` items, `home-composer.css`, `styles.css`,
`web/src/api/client.ts`, `api/mappers.ts`, `domain.ts`, `App.tsx` (session
kind routing), preview harness states. iOS: `client/lib/presentation/screens/
home_screen.dart`, `chat_screen.dart`, `mixes_screen.dart`,
`widgets/home_panel.dart`, `mix_prompt_input.dart`, new `album_card.dart`
and `listen_later_row.dart`, `providers/dj_providers.dart`, `data/dj/
dj_models.dart`, `dj_api.dart`, `data/musickit/musickit_bridge.dart`,
`client/ios/Runner/MusicKitBridge.swift`. Server owners are in the plan.

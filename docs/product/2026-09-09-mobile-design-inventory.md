# Mobile feature and design inventory

September 9, 2026. Working features plus clearly marked planned additions.

Purpose: agree the product's destinations and design each surface individually,
using a shared mobile visual system. This is an inventory, not an approved new
navigation or visual design.

The founder reports a successful mobile feature smoke. This inventory also reads
the current local Flutter implementation, including ongoing uncommitted work.
“Present” means a native implementation exists; it is not an independent claim
that every branch was covered by that smoke or deployed. Older roadmap statuses
are superseded where current code provides more recent evidence.

## Present feature families

| Area | Features to preserve | Surfaces to design |
| --- | --- | --- |
| Sign-in | Apple and Google sign-in; last-used method; pending, cancelled and failed sign-in | Welcome/sign-in |
| Music setup | Choose Apple Music or Spotify; Apple authorization and library sync; Spotify setup guidance | Service choice; connection/sync sheet; setup progress |
| Spotify imports | Exportify ZIP/CSV quick start; official Account data and Extended streaming history; local file selection and files opened into the app | Import guide; file picker handoff; import flow |
| Import review | File/count summary; collection roles and replacement targets; private-session choice where applicable; upload; refresh/re-import; partial results and retry | Review form; progress; success, partial and failure results |
| Taste introduction | Favourite artists, usual music, listening situations, exclusions and era preferences | Taste interview |
| Home / mix collection | Prompt with rotating examples; recent mixes; reopen; inline rename; archive with Undo; Active/Archived list and restore | Home; mix row; anchored actions; empty/error states |
| Playlist inspiration | Pick/search a reference playlist; attach, replace or detach it; optionally exclude source songs; start from playlist detail | Composer attachment and picker; playlist detail action |
| DJ conversation | Create a mix; follow-up requests and refinements; clarifications; DJ replies; generation progress; failed-turn retry; mix preview | Conversation; composer; message and preview components |
| Mix arrangement | Ordered songs and artwork; reveal song reasons; drag to reorder; swipe to remove; conversational refinement | Full mix/queue view; track rows; action feedback |
| Playback and output | Play through Apple Music handoff; create an Apple Music playlist with name/description; Spotify track links and transfer-tool handoff when available | Mix actions; playlist-creation dialog; provider availability states |
| Saved mix versions | Local list/detail/restore implementation; open from conversation actions or version chips; restore confirmation and conflict recovery | Version list; version detail; restore confirmation/result |
| Your music | Source connection/import status and dates; import again; remove imported source data; entry to playlists | Music overview; source row; removal confirmation |
| Playlist browsing | Artwork, counts, ordered entries, pagination, unmatched/local song labels | Playlist browser and detail |
| Playlist taste | Explicitly confirm a playlist was personally curated; reverse confirmation; neutral/ineligible states | Playlist detail control and confirmation |
| Existing-playlist editing | Separate private DJ draft; source/draft comparison; review changes; revised-copy apply and recovery UI | Draft conversation; review sheet; apply result. Code exists; narrower write-path verification/release gates remain recorded in backlog |
| DJ memory | View remembered preferences; explicitly forget a note with confirmation; remembered preferences can originate in conversation/interview | “What the DJ knows”; note row; forget dialog |
| Account | View identity and linked Apple/Google methods; link/unlink with last-method protection; refresh methods; sign out | Account and method-management feedback |

Keep two kinds of history distinct: Home holds different mixes; version history
holds earlier arrangements of one mix. Likewise, a mix and a saved provider
playlist are different objects. Creating or restoring a mix does not silently
rewrite a saved playlist.

## Planned additions that affect the design

The September 9 next-features program is the current scope reference. Saved mix
versions have already moved into local implementation above; do not list them as
wholly future work because an older backlog paragraph still does.

| Addition | Design impact | Current boundary |
| --- | --- | --- |
| Richer energy journeys | Composer presets; an understandable opening/middle/ending view in mix detail | Basic arc intent exists; richer controls and evaluation are planned |
| In-app Apple player | Persistent mini-player; expanded Now playing; transport/progress; unavailable-track states | Current native playback uses system-player handoff; app-owned playback is planned |
| Playback learning | Learning on/off and clear-history controls; explain what the DJ learns | Automatic observed playback learning is planned; explicit taste signals already exist |
| Routine suggestions | Home cards with a brief reason, dismiss and turn-off controls | Planned; requires enough repeated listening-session evidence |
| Apple deeper-history import | Apple “Go deeper” guide and review using the shared import flow | Server contracts exist; Apple archive adapters remain planned |
| Private blends | Create blend; invitation preview/acceptance; members; shared mix; leave/end controls | Planned, private and invite-only |
| Taste twins | Opt-in discovery; taste preview; matches; block/report and privacy controls | Planned; discovery consent and operational release gates apply |

Later ideas, outside the immediate selected program: structured remembered
companions, editable profile name, and a listening diary. A per-day ledger is
data infrastructure, not automatically a shipped diary screen. Direct Spotify
connection is conditional on provider access, not the current import model.

## Current navigation and decisions to make

Current native structure:

- Sign-in → service setup → Home.
- Home → conversation → full mix, version history or playlist creation.
- Home menu → Your music → playlist browser → playlist detail → private edit draft/review.
- Home menu → Spotify import, sync, setup, DJ memory, Account or sign out.
- Home has Active/Archived views; these are not separate global destinations.

The approved September 8 Home intentionally uses a compact global menu. It has no
root back arrow or dedicated playlist shortcut. This is the baseline; a bottom
navigation bar would be a new design choice in this session.

Suggested grouping for discussion:

| Destination | What belongs there |
| --- | --- |
| Home | Start a mix, recent/archived mixes, future routine suggestions |
| Your music | Playlists, connected/imported sources, sync and import actions |
| What the DJ knows | Explicit memories; future playback-learning controls |
| Account | Identity, login methods, sign out; future profile/privacy controls |
| Together — future working label | Private blends and opt-in taste twins |

Conversation, mix arrangement and version history sit inside a mix. Import and
sync are flows under music. Rename, forget and restore are contextual controls.
This keeps the global menu focused on places people return to, not every action.
Whether the first two destinations need persistent navigation remains open.

Update 2026-09-17: the shape, menu and foundation proposal is drawn in
`docs/mockups/2026-09-17-mobile-shape-and-map.html` (Option A, Home hub plus a
You sheet, recommended over a tab bar). The founder replaced that proposal on the same day with a four-tab shape
(Home, Mixes, Library, You), boxy layout, prism motif, gradient background,
Apple Music style titles and playback controls, and native Liquid Glass with a
fallback. Revision 2 (`docs/mockups/2026-09-17-mobile-shell-r2.html`) was reviewed and
revised the same day: no serifs, no containers, flush native lists, a Playground
style Home panel with a mic, a visible glow and a smaller dock. Revision 3,
`docs/mockups/2026-09-17-mobile-shell-r3.html`, was approved the same day with
amendments (`docs/mockups/approved/2026-09-17-mobile-shell.md`); the individual screen boards follow in the order listed in revision 1.


Update 2026-09-17, later: Home, conversation and arrangement boards were
approved the same day (`docs/mockups/approved/2026-09-17-mobile-*.md`). The
founder chose to finish the remaining screens in the app rather than on
boards. Implementation plan: `docs/superpowers/plans/2026-09-17-native-design-implementation.md`.

## Shared mobile design foundation

Web references: `web/src/styles.css`, `web/src/components/Cassette.tsx`,
`Icons.tsx`, `ProviderMarks.tsx`, `QueuePanel.tsx` and `web/public/tape.svg`.
Native currently starts from Material 3 themes seeded with plum in
`client/lib/main.dart`, with a small set of feature widgets and no equivalent
central brand asset/token system.

Build a common vocabulary before styling screens individually:

- Tokens: semantic light/dark colours, type scale, spacing, radii, borders,
  elevation, touch targets and motion. Tokens are named values shared by screens.
- Typography: readable body text, handwritten brand/mix titles and quiet metadata;
  choose actual native font assets and preserve descenders and large-text layouts.
- Assets: wordmark, cassette variants, custom icons, provider marks, artwork
  fallback and useful empty-state illustration. Adapt web SVG artwork for Flutter.
- Surfaces: neutral backgrounds, restrained translucent chrome, artwork-derived
  colour, clear layering for sheets/dialogs. Web's shared content-plane treatment
  is a reference; native blur/performance and text contrast need their own review.
- Components: buttons, composer, attachment picker, mix row/card, track row,
  source row, message, status, tabs, menu, sheet, dialog and Undo feedback.
- Behaviour: keyboard-safe composer, reachable controls, scroll/swipe/drag rules,
  loading transitions, accessible alternatives to gestures and reduced motion.

Retain the established no-decorative-left-border rule and compact secondary
actions with comfortable touch targets. Use “mix”, “play now” and “create playlist”
consistently in new copy.

## Individual design checklist

1. Mobile foundations and navigation shell.
2. Home: returning, first mix, active/archived, rename and archive feedback.
3. Conversation: prompt, replies, generation, clarifications, attachments and retry.
4. Mix detail: arrangement, reasons, playback handoff and playlist creation.
5. Mix versions: list, detail and restore.
6. Your music: sources and playlist browsing/detail, including taste confirmation.
7. Music setup and import: service choice, sync, Exportify, official history and review/results.
8. DJ memory and taste interview.
9. Sign-in and Account.
10. Existing-playlist draft/review, within its established write capabilities.
11. Planned player, energy and suggestions surfaces.
12. Planned Apple history and social/privacy surfaces.

Each screen needs populated, empty, loading and failure states where applicable;
also disabled actions with reasons, permission loss, long titles, missing artwork,
keyboard-open, short-phone, large-text, light/dark and reduced-motion checks.
These are variants of a screen, not extra navigation destinations.

## Evidence

- `client/lib/presentation/screens/` and `client/lib/presentation/widgets/`
- `client/lib/main.dart`
- `docs/product/vision.md`, `docs/decisions.md`, `docs/backlog.md`
- `docs/superpowers/specs/2026-09-09-next-features-design.md`
- `docs/mockups/approved/2026-09-08-mobile-home.md`
- `web/src/styles.css` and `web/src/components/`

Documentation-only inventory; no product code or existing approvals changed.

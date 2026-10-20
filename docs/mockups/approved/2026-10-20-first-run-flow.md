# Approved first-run flow — revision 2

Approved October 20, 2026: founder replied "Approved" to
[first-run states, revision 2](../2026-10-20-first-run-flow-states.html),
after three amendments applied the same day (graphic backgrounds, cap and
sheet without provider buttons, outlined back button). Spec:
`../../superpowers/specs/2026-10-20-first-run-flow-design.md`. Decisions:
`../../decisions.md` → 2026-10-20.

## Winning direction

A new listener reaches a mix before an account. Welcome carries the composer
field and one pill, Add my music first. Path A: Welcome, Who do you love?
(three artists), Mix, then the Keep this mix sheet. Path B: three counted
steps (Which do you use?, How do you want to add it?, the doing page), then
the prompt page, Mix, sheet. Sign-in is one page, reached from the sheet,
the cap, the You row or the welcome foot link, and never required first.

Rejected: Welcome as two pills (one more tap on the common path, and a
question the page then does not let the listener answer). Provider buttons
inside the Keep sheet or the composer panel (founder: strange and ugly). The
reference's round filled back button (copied shape).

## Locked behaviour

- Every first-run page is one question: a headline, at most one line, then
  stacked 56 pt paper pills. Path B pages carry "STEP n OF 3" and a 2 px
  progress line filling a third per step; path A has no counter.
- Backgrounds: the six generated grainy silk-marble images in
  `../2026-10-20-first-run-assets/` (magenta Welcome and prompt-after-sync,
  violet artists, blue Step 1, green Step 2, amber Step 3, plum black
  sign-in and cap). Identical in light and dark; a full-page scrim keeps cream
  text at 4.5:1 or better. Shipped as static assets at 2x and 3x, never drawn
  at runtime. Mix, Home and You keep the app gradient.
- Text on graphic pages is cream (#EFE6DA); pills are paper (#E8DFCF) with
  dark text and no shadow; disabled Continue is translucent paper with the
  hollow fast-forward glyph (state is weight plus glyph, never opacity alone).
- Back is the app's tape shape as a 1.5 pt outline with no fill, 40 pt tall
  with the 6 pt top and 10 pt bottom radii, carrying the rewind glyph; cream
  on graphic pages, text colour on gradient screens. 44 pt target.
- Welcome: wordmark, cassette with turning hubs, "What do you want to hear?",
  composer with rotating examples, the "or" divider, Add my music first, and
  "Already have an account? Sign in." at the foot.
- Who do you love?: three fields becoming chips; Continue enables at three.
- Step 1 line: "Mixes get better when the DJ knows your music." Skip for now
  goes to Who do you love?.
- Step 3 pages keep the existing instruction copy; Apple sync shows a live
  count, failure keeps the count and offers Retry and Continue with what's in.
- Keep this mix sheet: headline, line, one paper pill Keep this mix (opens
  the sign-in page), Not now. Shown once per session.
- Cap: the composer never changes. A fourth anonymous mix pushes the sign-in
  page with "That's three mixes on this device. Sign in to keep going, and to
  keep these."; back returns to Home with the prompt kept.
- Sign-in page: the existing screen on the plum black background, headline
  "Keep your mixes." when reached from the sheet, cap or You row.
- You tab, anonymous: one flush row, "Sign in to keep your mixes", in place
  of the identity block; no Sign out.
- Merge notice (existing account): the approved compact toast, two lines.
- Web: the same pages in a 420 px centred column on the full-bleed image;
  at 390 px the column is full width with 20 px gutters.

## Accessibility

VoiceOver page names carry the step ("Step 2 of 3, How do you want to add
it?"); the progress line has no value of its own. 200 % text wraps headlines
and grows pills, the page scrolls, foot lines stay after the content. Reduced
motion stops the hubs, cross-fades pushes and jumps the progress line.
Reduced transparency changes nothing on graphic pages (pills are already
opaque; the images are not a material). Sync counts are a polite live region
at most once per ten seconds; failure is an alert.

## Platform differences

iOS and web share the pages, copy and images. iOS pushes with the native
navigator; web uses history so the browser's back answers the outlined
button. The web frame crops the portrait image at wide sizes, which coarsens
the grain; accepted.

## Unresolved implementation details

- Final scrim stops per image if the founder wants the silk brighter (the
  fix is darker images, not a lighter scrim).
- Exact asset sizes for 3x and the web.
- Whether the artist fields offer catalogue completion (not drawn; plain
  text fields are approved).

## Owners

Server: `server/src/auth/create-auth.ts`, `server/src/routes/sessions.ts`,
new `server/src/auth/link-anonymous.ts`, `server/src/enrich/scheduled.ts`,
migration 0035. Web: `web/src/RootApp.tsx`, new `web/src/components/first-run/`,
`web/src/lib/auth-client.ts`. iOS: `client/lib/main.dart`, new
`client/lib/presentation/screens/first_run/`, `client/lib/data/auth/`.

## Supersedes

- The once-only service choice (`ServiceGate`, `ChooseServiceDialog`) from
  the 2026-09-01 listening-export spec and the 2026-09-08 mobile parity
  approval. Library's Add your music reuses the new Step pages.
- Sign-in as the first screen on both platforms. The sign-in page itself is
  unchanged apart from its headline and background.

Earlier records are not rewritten. The 2026-09-17 shell and 2026-09-25 polish
approvals stand for everything after the first mix.

## Implementation departures (2026-10-20)

Recorded after Tasks 5 to 10 landed; the approval above is unchanged.

- Web Step 2 for Apple Music offers only "Sync my library": the web has no
  reader for Apple's export file.
- The web Apple sync page drives the same sync run the Sources panel uses,
  without that panel's chrome. Exportify and data-export instructions are the
  existing full lines (eight data-export steps, not seven).
- The sign-in page keeps the existing web card on wide widths and becomes
  cream-on-image under 760 px; its headline stays in the existing welcome
  style. The welcome foot link also opens it on the plum image, with the
  default headline.
- The Keep sheet and `first_mix_made` also fire when a refused first mix is
  filled by a follow-up turn, on both platforms. "Once per session" is the
  browser tab's session on web and the app launch on iOS.
- A prompt kept across the cap is re-sent without its playlist attachment; the
  draft and the shape are kept apart and composed at send.
- iOS: the sheet reuses `MixtapeSheet` (20 pt corner, not the board's 26);
  the first-run images ship at 2x only; the link from an anonymous session
  remounts the root and lands on Home, not the mix.
- The composer's send key appears only with text (existing composer), and the
  sync count starts at "0 songs so far".
- iOS Library's "Add Spotify music" still opens the old request screen; the
  new steps are reached from Library's "Add your music".

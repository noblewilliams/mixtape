# Energy journeys — local implementation evidence

Implemented for new-mix and conversation composers on web and Flutter. The four
approved choices are Steady, Build gradually, Wind down, and Build, then settle.
Use this shape adds an editable sentence to the brief; generation still requires
an explicit send. Cancel leaves the brief untouched. The helper replaces only its
own exact preset line and refuses to truncate a 2,000-character brief. Ordinary
conversation remains authoritative; the existing DJ interprets the visible brief
through its existing validated energyArc tool input.

The curator remains Sonnet. This change does not introduce an automatic reorder,
extra model call, playback action, or saved-playlist mutation. Current-queue context
now includes measured energy with explicit unknown values; edit_queue can record
an explicit new shape. Eligible candidate selection and deduplication are retained.

Every new version can retain energyArc and energyJourney. The assessment reads the
committed positions inside the snapshot transaction. Edits inherit the last shape
unless explicitly changed; a new generated brief can clear it. Restore copies the
original assessment. Later enrichment never rewrites old snapshots. Legacy versions
have no fabricated shape. Migration 0030 adds nullable fields after pending 0029.

Assessment uses opening/middle/ending thirds by track count, not elapsed duration.
Each third needs at least two known energies and 2/3 coverage. Invalid/out-of-range
values remain unknown; zero is valid. Rise/fall require a 0.15 opening-to-ending
change with 0.05 tolerance between thirds; arc requires the middle to exceed both
ends by 0.15; steady permits a 0.12 range. These are coarse engineering heuristics,
not validated perceptual scores. UI shows follows/mixed/limited prose, never a
precise measured curve. The illustrated picker curve is explicitly a target.

Evidence:
- Red-first evaluator and composer tests failed before implementation.
- Full server suite: 82 files passed, 1 skipped; 1,336 tests passed, 1 skipped.
- After the final edit-intent fix and enrichment immutability regression: 85 focused
  loop/history/curator tests passed; TypeScript check passed.
- Full web suite: 46 files passed, 1 skipped; 377 tests passed, 1 skipped.
- Final web energy/history/App checks: 9 passed; production build passed.
- Native composer/home checks: 17 passed. Final energy/history/chat checks: 35 passed,
  including 320×568 at 200% text. Native analysis checked the changed production paths.
- Browser reviewed the real picker and apply flow at /qa/energy.html. Native dark
  picker rendered and visually inspected at /tmp/mixtape-energy-screens/energy-native-dark.png.
- Existing web bundle-size advisory remains.

The golden cases are deterministic evaluator/prompt/eligible-output tests. They do
not establish live Sonnet listening quality or auditory acceptance. No new provider
or physical-device playback claim is made. Local source only: migrations 0029/0030,
matching API deployment, and a refreshed native build remain release work.

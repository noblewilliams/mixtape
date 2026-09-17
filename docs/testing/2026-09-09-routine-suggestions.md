# Routine suggestions — local implementation

Implemented on Home in web and native, following the approved six-feature board.
The card has Make this mix, Not today, and Suggestion settings. Actions stay compact;
containers use full outlines without decorative left borders. No qualifying pattern
leaves the ordinary mix entry available, with an honest learning-state message.

## Pattern contract

The initial detector uses only the original mix version's energy arc (rise, fall,
arc, steady) and session creation time. It never reads prompt text, message text,
private titles, lyric text, imported listening counts or playback evidence. Later
mix edits cannot retroactively change the original routine. Missing original
snapshots/energy intent produce no inferred pattern.

A qualifying mix is personal, unarchived, and has at least three entries in its
original snapshot. Query at most 500 recent sessions from the last 84 days. Group
by current IANA time zone, weekday, six-hour window, and energy arc. Require three
distinct local dates spanning at least 14 days. Duplicate sessions on one day do
not raise confidence. Return at most one suggestion, ranked by distinct dates,
with a deterministic tie break. Labels and generation briefs are fixed broad
copy, not excerpts or model-written interpretations of sensitive requests.

The account must still have at least three in-library tracks. Home refreshes on
entry, foreground/resume and approximately each minute while visible. Each Make
this mix request rechecks eligibility, preference and dismissal before returning
a brief to the normal creation path. Manual creation starting while validation is
pending prevents a second creation. A suggestion does not inherit an unrelated
playlist attachment. Normal DJ validation/error handling remains authoritative.
There is no background model invocation, automatic playback/save, or notification.

Suggestions default on, with a persistent account-wide off switch. Not today stores
a pattern dismissal server-side, suppressing it through the current local date
(with a 36-hour maximum for travel/clock boundaries). Dismissals are keyed by the
bounded weekday/window/arc vocabulary; stale entries are pruned on writes. Preference
writes preserve dismissals and concurrent dismissals merge under a row lock. Account
deletion cascades. These preferences are independent of playback-learning consent.

Clients resolve the current device/browser time zone for every read/action. Native
zone lookup failure exposes retry instead of inventing a UTC routine. Requests that
complete after account-surface disposal cannot start generation; native settings
also invalidate on account change. Failed preference writes retain the prior state
and expose retry. Successful off/clear of unrelated listening evidence has no effect
on this separate session-pattern feature.

## Verification

- Red-first detector and authenticated route-store seams: thresholds, distinct dates,
  future/old/unknown data, DST and local day conversion, account isolation, archived
  and non-personal exclusions, original-version attribution, library removal,
  stale selection, persisted dismissal/off, and absence of automatic generation.
- Full server suite: 86 files passed / 1 skipped; 1,347 tests passed / 1 skipped.
  Later focused suggestion and pending-migration checks passed; server types pass.
- Full web suite: 50 files passed / 1 skipped; 391 tests passed / 1 skipped.
  Later five component tests cover explicit generation, expired selection, dismissal,
  failed preference save, account-surface disposal and concurrent manual creation.
- Native Home and suggestion tests: 47 passed. Includes 320×568 with 200% text,
  expired/late responses and persisted off/dismiss behavior. Scoped analysis passes.
- Web production build and unsigned iOS debug build pass. The existing web bundle-size
  advisory remains. No app installation or production deployment was performed.
- Synthetic browser card/settings reviewed at desktop and 320px widths using
  `web/qa/suggestions.html`. Native rendered card reviewed at
  `/tmp/mixtape-routines-screens/routine-native-dark.png`; interaction tests exercise
  large text. Synthetic content is not evidence of a real user's qualifying routine.

## Release gate

Migration `0032_soft_supreme_intelligence.sql` adds only account suggestion settings.
It follows pending 0029–0031. Release the matching API/web and install the updated
native build together, using an isolated committed checkout. Verify one real account
with qualifying sessions after release. Apple deeper-history import is the next
approved implementation slice; real archive-layout acceptance remains separate.

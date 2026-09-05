# Listening-export release and validation

**Status:** draft release contract with partial execution recorded, 2026-09-05
**Scope:** release the completed listening-export, web music, playlist
intelligence, and Phase 3 enrichment work; validate it with real Spotify exports;
establish the evidence gate for Phase 4.
**Implementation baseline:** `bba5de9` (music/enrichment/playlist intelligence)
and `3d18a17` (Your music web integration) on `main`.
**Selected release candidate:** application tree `05dad49`; Worker snapshot
`fd5f66b` adds only the migration record and is deployed. Netlify production is
on `05dad49`. Detailed Worker execution record: `7a2a514`.

Read with the [2026-09-01 listening-export design](2026-09-01-listening-export-import-design.md),
the [2026-08-31 artwork and playlist-intelligence design](2026-08-31-artwork-playlist-intelligence-design.md),
the [2026-09-04 release preflight](../plans/2026-09-04-playlist-release-preflight.md),
the [fallback-art plan](../plans/2026-09-04-spotify-fallback-artwork.md), and
the [program handoff](../../handoff.md).

## Goal

Move the implemented work from a locally verified Git snapshot to a recoverable
production release, then prove listener-facing behavior against the founder's
real Spotify exports. The archive stays on the listener's device. Only normalized
identities, day totals, library evidence, artists, and playlist snapshots cross
the application API.

Release success means:

1. One reviewed Git SHA identifies the migrations, Worker, web build, and iOS
   candidate.
2. Production schema reaches the version required by that code before a new
   client calls it.
3. Spotify oEmbed works from Cloudflare. Deezer is either verified as a guarded
   exact-ISRC fallback or recorded as unavailable without blocking Spotify art.
4. The founder imports both Spotify packages on the launch surfaces, creates a
   personal mix, uses an output, and re-imports without changing the result.
5. Production has non-synthetic `import_completed` and `first_output` funnel
   evidence before Phase 4 product work begins.
6. Every production step has a clear stop or rollback path.

## Current evidence

Fresh isolated checks on `05dad49` passed 73 server files / 1,259 tests, server
typecheck, Drizzle consistency, and an `0014`-to-`0024` migration rehearsal; 36
web files / 349 tests and a production build; 540 Flutter tests, analysis, and an
unsigned simulator build; fixture verification; and a Wrangler dry-run. The
deployed `fd5f66b` changes only the release record, not application code.

At spec creation, the last read-only production check found migrations through
`0014`, and local `main` was 106 commits ahead of `origin/main` and not behind.
That is historical context: the reviewed foundation through `05dad49` was later
pushed, and production now has matching migrations through `0024`. Re-read the
production ledger and Git remote before the remaining rollout actions.

The shared checkout intentionally contains founder-owned changes to `AGENTS.md`,
`CLAUDE.md`, and `.claude/launch.json`. They are not release inputs. Build,
migrate, and deploy only from a clean worktree at the selected commit.

### Partial execution update — 2026-09-05

- The reviewed foundation through `05dad49` was pushed to `origin/main` after
  explicit approval; `fd5f66b` records the migration result.
- Production was verified as an exact migration prefix through `0014`, with
  matching hashes. The ordered `0015–0024` chain was then applied from a clean
  detached `05dad49` worktree. The post-run ledger has 25 matching entries
  through `0024`, and the four new core tables resolve.
- Worker snapshot `fd5f66b` is live as version
  `7a6ec181-2292-4d56-b8a4-abb996d6857a`, with rollback version
  `e35b134c-c045-4267-92b6-31c42c918159`. Public health/auth guards and an
  aggregate private status check passed. The first bounded scheduler pass
  materialized 25 catalog tracks and raised linked playlist entries from 353 to
  379, leaving 954.
- Netlify production reports commit `05dad49`. Code-affecting pushes to `main`
  must now be treated as production publishing. This auto-publish happened
  before the Worker rollout was complete, so the intended compatibility order
  was not demonstrated; production browser smoke remains required.
- No Spotify-oEmbed/Deezer-specific smoke, playlist mutation, TestFlight action,
  device smoke, or real-export smoke occurred. Initial private checks returned
  aggregate counts only; no track or playlist metadata was read.
- The execution record does not document a Neon restore point or every
  postcondition below. Keep those acceptance items open until evidence exists.

## Remaining scope before the exports arrive

- [x] Correct stale release wording in the handoff and phase plans.
- [x] Fetch the remote, review the complete candidate diff, and select one exact SHA.
- [x] Determine whether pushing `main` triggered Netlify production. It did;
  future code-affecting pushes need a release branch or an explicitly compatible
  backend/schema state first.
- [x] Rerun server, web, client, fixture, migration, and Worker-bundle gates from a
  clean worktree.
- [ ] Run the public-ID-only Cloudflare provider smoke below.
- [ ] Record a recoverable Neon restore point/branch. The production prefix and
  local rehearsal were verified, and the migration chain is already applied.
- [x] With explicit action-time approval, push and migrate.
- [x] With separate approval, deploy the Worker and publish the web build.
- [ ] Smoke the production web build and prepare TestFlight.

## Scope after the exports arrive

- Inspect the Spotify Account data and Extended streaming history layouts
  outside the repository. Express mismatches as small synthetic fixtures; never
  commit the founder's rows or archive bytes.
- Validate Spotify import on iOS, desktop Chrome, and Android Chrome.
- Confirm ledger, library, playlist, source-deletion, enrichment, mix, output,
  idempotency, and funnel behavior against real data.
- Inspect the Apple archive structure only to inform Phase 5. The Apple “go
  deeper” parser is not implemented in this release, so this spec does not claim
  the Apple export can be imported.

## Out of scope

- Scrobble relay and Spotify iFrame product implementation. This release only
  decides whether their Phase 4 gate is met.
- The Phase 5 Apple Media Services parser or iOS implementation.
- Physical track-row merging, fuzzy identity matching, or inferred membership.
- Reconciliation of migration-0022 `legacy` memberships.
- Conversational playlist editing, native apply changes, or new UI design.
- Resetting exhausted enrichment attempts or performing an unreviewed backfill.

## Release unit

One immutable Git SHA owns these artifacts and records:

- Worker dry-run bundle and final Cloudflare deployment version;
- web production build and Netlify deploy identifier;
- iOS archive/TestFlight build number;
- ordered migration list and pre/post ledger state;
- exact test commands/results;
- provider report containing only fixed category, schema-valid boolean, and
  elapsed time;
- production smoke results and rollback references;
- later real-export report containing counts only.

Do not mix later working-tree files into an artifact or stage the three local
instruction/launch files.

## Provider smoke

Use an ephemeral Cloudflare-hosted Worker context with no database binding, user
token, listener data, or public application route. Remove it after collecting
the fixed result fields.

### Spotify oEmbed — release blocker

Use one known public Spotify ID and one syntactically valid nonexistent ID.

Pass conditions:

- the known ID returns within the five-second application timeout;
- the documented envelope and fixed HTTPS `i.scdn.co/image/...` URL validate;
- the missing ID uses the typed no-match path;
- the response remains within 256 KiB;
- output contains no ID, title, artist, request URL, artwork URL, or body.

A timeout, authorization response, persistent 5xx, changed host, or changed
schema blocks release until the assumption or adapter is reviewed.

### Deezer exact-ISRC — non-blocking contingency

Use one known public ISRC, never one from a listener archive. Accept artwork only
when the response repeats the exact ISRC and uses the allowlisted Deezer CDN.

| Result | Release behavior |
|---|---|
| Exact ISRC and valid cover | Keep enabled and record schema/latency success. |
| No match | Keep bounded no-match retry. |
| 401/403 or token required | Record Deezer unavailable; Spotify remains supported. |
| Changed/malformed response | Keep it rejected; do not loosen validation during release. |
| Timeout/429/5xx | Confirm fixed-category backoff; do not block a Spotify-valid release. |

Deezer never writes identity or membership and is not required for importing,
mixing, or output.

## Release-candidate verification

Run from the clean worktree at the selected SHA:

| Area | Required check |
|---|---|
| Server behavior | `npx vitest run --no-file-parallelism` |
| Server types | `npm run typecheck` |
| Schema history | `npx drizzle-kit check` and the `0014`-to-current rehearsal |
| Worker artifact | Wrangler minified deploy dry-run; inspect bindings/size without secret values |
| Web behavior | full web test suite |
| Web artifact | production TypeScript/Vite build |
| iOS behavior | full Flutter tests and analyzer |
| iOS artifact | unsigned simulator build before signed archive work |
| Export fixtures | structural archive check and both parser contract suites |
| Git hygiene | clean worktree and exact reviewed commit/files |

A candidate-caused failure is fixed and its affected gate rerun. An unrelated
baseline failure must reproduce on the prior commit before being recorded as
baseline rather than release risk.

## Migration contract

Production ended at `0014` immediately before this release. The applied chain was:

| Migration | Purpose |
|---|---|
| `0015` | staged, deletion-safe library sync |
| `0016` | web recent-track observations |
| `0017` | playlist sync source identity |
| `0018` | listening-export schema, Spotify identity, sources, funnel, relaxed Apple-only fields |
| `0019` | liked-track reconciliation results |
| `0020` | bounded playlist catalog lookup state |
| `0021` | exact playlist creation-origin evidence |
| `0022` | per-source saved-library ownership and protected `legacy` backfill |
| `0023` | Apple exact-ISRC state and catalog storefront |
| `0024` | session playlist-inspiration state |

The release procedure required:

1. Verify production is an exact prefix of repository history.
2. Record schema and aggregate row-count invariants without music names or raw
   listening data.
3. Create and verify a recoverable Neon restore point or branch.
4. Apply the chain to a production-shaped copy and run postconditions.
5. Obtain explicit approval for the exact production list and Worker SHA, with
   migration before deployment.

Postconditions:

- migration count, order, and hashes match the selected repository history;
- existing user, track, user-track, session, and playlist counts remain stable
  except documented backfills;
- every prior `user_tracks.in_library = true` row gains protected `legacy`
  membership after `0022`, with no false membership;
- old playlist runs default to `ios_native`; existing sessions have disabled/no
  playlist inspiration;
- new foreign keys, checks, and indexes validate;
- no duplicate provider ID, lookup key, or source membership is introduced.

The chain was applied successfully. It is additive or broadens nullable/source
support, apart from the intentional `legacy` backfill. It has no reviewed down
migration. If application behavior fails, do not hand-edit the ledger. Redeploy
the previous Worker or prepare a separately reviewed forward repair; use a
verified restore point only when one has actually been recorded.

## Deployment order and rollback

Execution completed candidate selection/fetch, all clean-snapshot checks, push,
the production-ledger reread, migration application, Worker deploy, initial
public/private smoke, and Netlify publication. It does not record a restore
point, provider-specific smoke, browser/device smoke, or real-export validation.
Continue from the current production ledger and deployed versions rather than
replaying the migration chain.

1. Freeze the release SHA; fetch and confirm remote/Netlify behavior.
2. Finish all candidate checks and provider smoke.
3. Push without allowing an incompatible web build into production.
4. Re-read the production ledger/Worker version and create the restore point.
5. Apply approved migrations through the selected endpoint.
6. Deploy the Worker from the clean worktree.
7. Run health, auth, source, browse, session, and counts-only maintenance smoke.
8. Promote the web artifact; smoke Apple/Google login, Apple Music authorization
   separation, Your music, playlist browse/detail, sessions, and Spotify output.
9. Build/sign/upload iOS; physically verify sign-in, permission denial, archive
   handoff, cancellation, foreground return, Sources, mix output, and iPad share.
10. Observe production health before using the real archives.

If Worker deployment fails after migration, redeploy the previous Worker and
leave the additive schema while diagnosing. If web fails, restore the prior
Netlify deploy. If iOS fails, do not promote the TestFlight build. Never roll
back from the dirty shared checkout.

## Real Spotify export validation

### Archive handling

- Keep archives outside Git, server requests, and logs.
- Inspect filenames, nesting, compression, JSON encoding, fields, nullable
  values, playlist identity, dates, and time-zone representation.
- Compare shapes to `fixtures/listening-exports/README.md` without copying music
  names or raw rows into diagnostics.
- Capture differences in minimal synthetic fixtures with invented data.
- Rerun web and iOS parser suites after any fixture/parser change.

### Data assertions

- Both packages import in either order and source state reports landed packages.
- Private-session plays are excluded by default and included only after explicit
  inventory opt-in.
- The 30-second rule, local-day conversion, skips, completions, and durations
  match manual checks.
- Three heavy-rotation recordings match manual totals, including one represented
  by multiple Spotify IDs; ISRC grouping prevents duplicate pool slots.
- Likes, artists, playlist order/duplicates/local items, and source deletion
  behave as specified.
- Spotify removal cannot remove Apple or protected legacy membership.
- Account-only data never invents observed play counts.
- An unchanged re-import returns the same summary and creates no duplicate days,
  memberships, origins, or playlists.

| Surface | Required flow |
|---|---|
| iOS physical device | Files/Mail -> inspect -> inventory -> import -> Sources -> personal mix -> open/share -> re-import |
| Desktop Chrome | choose Spotify -> inspect both packages -> import -> Your music -> playlist detail -> mix -> copy/open |
| Android Chrome | same browser flow, document picker, responsive states, copy/open, no overflow |

Permission denial, cancellation, partial playlist failure, lost completion
response, sign-out, and retry must preserve the last canonical snapshot. Reuse
fault-injection evidence; do not corrupt the founder's import to recreate errors.

## Funnel and Phase 4 gate

The counts-only report should show the founder path in order where applicable:

1. `chose_spotify`
2. `marked_requested`
3. `interview_completed`
4. `file_inspected`
5. `import_completed`
6. `first_personal_mix`
7. `first_output`

Phase 4 technical probes may be specified after production contains
non-synthetic `import_completed` and `first_output`. One complete founder path is
enough for short reversible feasibility probes, but not a broad relay/embed UI
rollout. That needs more listener evidence and a separate approved spec.

The relay probe must compare ListenBrainz and Last.fm terms, commercial use,
consent, latency, completeness, deletion, identity resolution, and outages. The
Spotify iFrame probe separately tests authentication, controls, events, mobile
browsers, and whether it yields useful feedback without claiming full telemetry.

## Privacy and disclosure gate

Before wider distribution:

- privacy policy names normalized listening history, membership, playlists,
  artists, retention, deletion, and third-party metadata lookup;
- App Store privacy labels match the iOS path;
- inventory truthfully shows what uploads;
- raw archives never leave the device;
- logs/reports contain counts and fixed categories only;
- user tokens, private keys, OAuth secrets, database URLs, response bodies, IDs,
  music names, and artwork URLs are not printed or persisted in unsafe storage;
- delete-source behavior is verified independently per source.

## Production observation

Monitor aggregate authentication/5xx rates, import begin/completion/expiry,
stale staging, source publish/delete counts, Apple ISRC result categories,
Spotify/Deezer artwork categories, enrichment remaining/retryable counts, and
the three output funnel milestones. Monitoring never contains music names, raw
rows, provider IDs, URLs, or response bodies.

## Acceptance checklist

- [x] Exact release SHA, migration list, and sequence received action-time approval.
- [ ] Netlify auto-publish cannot expose a client before schema/Worker readiness.
- [x] Clean-worktree candidate checks pass.
- [ ] Spotify Worker smoke passes; Deezer outcome is recorded.
- [ ] Production migration prefix and restore point are verified.
- [ ] Migrations and postconditions pass.
- [x] Worker and initial counts-only smoke pass.
- [ ] Web and launch-browser smoke pass.
- [ ] TestFlight and physical-device smoke pass.
- [ ] Privacy policy and App Store disclosure match the data path.
- [ ] Real archive shapes are captured in privacy-safe fixtures.
- [ ] Real imports, manual counts, outputs, deletion, and idempotency pass.
- [ ] Funnel contains non-synthetic `import_completed` and `first_output`.
- [ ] Release record contains versions, evidence, observation, and rollback
      references without private music data.

## Reopen conditions

Revisit this contract if production is not an exact migration prefix, `main`
cannot be separated from web auto-deploy, Spotify changes oEmbed/CDN behavior,
Deezer gains a documented API contract, real archives do not fit the on-device
parser architecture, production-shaped migration rehearsal misses a constraint
or scale issue, or smoke finds a source-ownership/identity error.

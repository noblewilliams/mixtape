# Privacy disclosure — implementation draft

**Status:** working draft, not published or submitted. Prepared 2026-09-08 from
local code at `05ba8b1` and the web-controls changes. Business-policy facts and
production service settings remain unverified.

## Proposed listener-facing explanation

Mixtape uses the music information you choose to bring and your conversations
with the DJ to make personal mixes. Signing in creates an account associated
with your identity provider. Account records include your supplied name, email,
and account identifier; session records can include IP address and browser or
device information for authentication.

When you import a Spotify export, the archive is parsed on your device. The
archive itself is not uploaded to Mixtape. Selected normalized information is
sent instead: song identities, listening totals by day, saved music, followed
artists, and playlist contents. Import country and time zone help interpret
catalog matches and listening dates. Private-session plays are excluded unless
you choose to include them during import.

Apple Music sync provides library and playlist information. Native iOS can
supply per-song play counts; browser sync does not invent those counts. Your
sources can coexist. Removing an imported source removes that source's evidence
according to its deletion rules; it does not erase music supported by another
source, protected historical membership, pasted seeds, or saved DJ notes.

Your prompts, mix conversations, requested memory notes, playlist drafts, and
mix interactions support personalization. Forgetting a saved note removes that
note; it does not remove the earlier conversation in which you mentioned it.
Archiving a mix hides it from the active list and preserves its conversation and
songs. Confirming that you personally curated a playlist provides a reversible
taste signal. Playlist inspiration provides context for one mix and does not
edit your source playlist.

Mixtape uses hosted services to run the app and database and to generate mixes.
Relevant prompt and music context is processed by the model and embedding
services. Public music identifiers are used for catalog matching, music features,
and artwork lookups. Import and output milestones are associated with your
account so we can understand whether the flow works; aggregate reports omit
music names. No lyric text is stored or displayed by the application.

## Engineering evidence and disclosure mapping

| Data / behavior | Source inspected | Candidate disclosure / purpose |
|---|---|---|
| Name, email, account ID; authentication session IP and user agent | `server/src/db/auth-schema.ts`, `server/src/auth/create-auth.ts` | Contact information and user identifiers for account functionality; confirm session telemetry classification |
| Listening dates/totals, library and playlist memberships | `server/src/listening/import-store.ts`, staged library/playlist contracts | Music listening/product interaction data for personalization and app functionality; linked to the account |
| Prompts, transcript, memory, drafts | `server/src/routes/memories.ts`, session and playlist-editing stores | User content for personalization and app functionality; linked to the account |
| User ID, milestone type, surface, timestamp | `server/src/routes/funnel-events.ts` | Product interaction for analytics; counts-only reporting does not make stored user-linked events anonymous |
| Model and embedding processing | `server/src/index.ts`, `server/src/dj/llm.ts`, `server/src/enrich/embedder.ts` | Anthropic and Cloudflare Workers AI processing; verify current vendor retention and account settings before publication |
| Catalog/features/artwork | MusicKit, ReccoBeats and provider-artwork adapters | Apple, ReccoBeats, Spotify, Deezer lookups; public identities rather than archive uploads |
| Hosting/persistence | Worker entrypoint, database driver and recorded Netlify deployment | Cloudflare, Neon, Netlify; verify regions, logging and retention in service configuration |
| Archive parsing and temporary native handoff | `web/src/import/`, `client/lib/import/`, `client/ios/Runner/AppDelegate.swift` | Archive stays local; temporary-copy cleanup is distinct from deleting the original archive |

Apple requires disclosure of collected data, including data used only for app
functionality, and relevant third-party practices. Its categories expressly
include music listening under Product Interaction. This table is a proposed
mapping, not submitted App Store answers. Review linked-data, tracking, user
content, search history, diagnostics, and any sensitive content actually handled
before submission. Do not infer “not linked” from aggregate output or “not
collected” from an optional import button. Source checked September 8:
[Apple app privacy details](https://developer.apple.com/app-store/app-privacy-details/).

## Retention and deletion facts still to resolve

- Import runs have a two-hour default open window. Staging cleanup is bounded
  and scheduled; an expiry timestamp is not an exact physical-deletion promise.
  See `server/src/listening/cleanup.ts` and shared playlist cleanup constants.
- No general lifetime limit for completed listening history, conversation,
  memory, funnel events, or account records was established in this pass.
- Source deletion is not account deletion. No end-to-end account deletion flow
  was verified. Do not promise an in-app account-deletion control without proof.
- Backup retention, vendor retention/training settings, hosted logs, and deletion
  propagation require production/operator verification.

## Required operator facts before publication

1. Legal operator name, contact email, operating jurisdiction, and policy URL.
2. Intended retention periods for account data, conversations, listening data,
   analytics, operational logs, and backups.
3. Account deletion request route, handling process and expected completion time.
4. Actual vendor regions, subprocessors, retention/training settings, and any
   analytics or crash SDKs enabled in the distributed native build.
5. Intended audience/age restrictions and any advertising, marketing, or data
   sharing practices outside the inspected implementation.

These unresolved facts block a final privacy policy and App Store submission,
not local feature development. No claim of legal compliance or final privacy
label accuracy is made by this draft.

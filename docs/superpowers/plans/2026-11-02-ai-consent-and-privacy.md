# AI consent and privacy policy — plan

**Status:** approved 2026-11-02 (founder: consent on first run before the first
mix; operator is Noble Williams, hello@noblewilliams.dev; data kept until you
delete it). App Store guideline 5.1.2(i) asks apps to say where personal data
goes, naming third-party AI, and to get explicit permission before sending it.

## Contract (server)

- Table `ai_consents (user_id PK → user.id ON DELETE CASCADE, version text,
  granted_at timestamptz)`, migration 0045. Moves with an anonymous listener
  on sign-up (link-anonymous table list).
- Current version: `2026-11-02` (`AI_CONSENT_VERSION`). A new version (new
  processor, new data) re-asks.
- `GET /me` adds `aiConsent: boolean`: true when the stored version equals the
  current one. **Clients treat a missing field as granted** (an older Worker),
  so they never gate against a server that cannot record the answer.
- `POST /me/ai-consent` body `{ "version": "2026-11-02" }` → `200
  { "aiConsent": true }`; a version other than the current one → `409
  { "error": "stale_consent_version" }`; 401 without a session. Idempotent.
- Enforcement behind `AI_CONSENT` (`off` | `enforce`, default `off` in
  `wrangler.jsonc`): with `enforce`, starting a session, sending a turn and
  `/transcribe` answer `403 { "error": "ai_consent_required" }` without
  consent. Turned on only after clients that ask are live.

## Copy (both clients, exact)

- Title: **Before your first mix**
- Body: **Mixtape’s DJ runs on Anthropic’s Claude. To make your mixes we send it
  what you type or say, and the music and listening history you add. Voice
  clips are transcribed by Groq. Your data is not sold or used for ads.**
- Link: **Privacy policy** → `https://miixtape.netlify.app/privacy/`
- Primary: **Agree and continue**. Secondary: **Not now**.

## Where it shows

- **First run:** after Welcome, before the first prompt is sent (the step that
  would call `POST /sessions`). Agree records consent and continues; Not now
  stays on the page and the mix is not sent.
- **Existing sessions:** when `/me` says `aiConsent: false`, the same content as
  a one-time sheet (iOS) or modal (web) over the app. Not now dismisses it for
  this launch; sending a prompt, starting voice or making an album pick
  re-shows it instead of sending.
- Anonymous listeners consent like anyone else; the row follows them on sign-up.

## Privacy policy

A static page at `/privacy/` on the landing build (same Netlify site), linked
from the landing footer, web Settings and iOS You/Account. Content from
`docs/releases/privacy-disclosure-draft.md` with the founder's facts: operator
Noble Williams (individual), contact hello@noblewilliams.dev; retention until
the listener deletes their account or source, anonymous data after 30 days
idle, provider logs and backups per their standard retention; in-app deletion;
processors Cloudflare, Neon, Netlify, Anthropic, Groq, Apple, ReccoBeats,
LRCLIB (lyrics are processed into themes, never stored as text), Spotify and
Deezer public lookups; no tracking, no ads, no sale.

## Gate (founder)

Deploy the Worker with `AI_CONSENT=off`; ship web and a TestFlight build; check
the first-run and existing-user prompts; then set `AI_CONSENT=enforce` and
redeploy.

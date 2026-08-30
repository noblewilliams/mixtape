// Shared by loop.ts (session context: queue summary, removal acks) and
// curate.ts (the candidate pool block) — both weave track titles/artists,
// which are user-controlled data synced from the listener's own library
// (see routes/ingest.ts), verbatim into an LLM prompt. A standalone module
// rather than an export off either of those files: loop.ts already imports
// curate.ts, so curate.ts importing sanitizeForPrompt back from loop.ts
// would be circular.
//
// Strips control characters (including newlines, so a crafted title can't
// fake a turn boundary or an instruction-like line break) and caps length so
// one oversized field can't dominate whatever block it's rendered into.
const DEFAULT_MAX_LENGTH = 80

export function sanitizeForPrompt(text: string, maxLength: number = DEFAULT_MAX_LENGTH): string {
  return text.replace(/\p{C}+/gu, ' ').slice(0, maxLength).trim()
}

// Shared by routes/sessions.ts's titleFromPrompt (the truncated-prompt
// fallback AND the PATCH /sessions/:id title field) and dj/loop.ts's
// rename_session tool — every place a session's own DISPLAY title gets
// sanitized before it's written to dj_sessions.title, so the three can't
// drift apart. A standalone module for the same circular-import reason as
// sanitizeForPrompt above: routes/sessions.ts already imports dj/loop.ts, so
// loop.ts importing this back from routes/sessions.ts would be circular.
//
// Trims BEFORE capping to length (unlike sanitizeForPrompt, which caps then
// trims) so a title's real content isn't pushed out by leading whitespace
// eating into the cap, then trims once more after the cap in case the cut
// point landed mid-whitespace. No quote-stripping here (unlike dj/title.ts's
// own sanitizeTitle, tuned for an LLM's raw completion, which might wrap its
// answer in quotes) — a user- or DJ-supplied title is free-form text, and
// stripping a leading/trailing quote from it would be actively wrong.
// Collapses internal whitespace runs to a single space (matching dj/title.ts's
// own sanitizeTitle discipline) so a title padded with tabs/repeated spaces
// doesn't display that way verbatim.
export function sanitizeTitleText(text: string, maxLength = 60): string {
  return text
    .replace(/\p{C}+/gu, ' ')
    .trim()
    .replace(/\s+/g, ' ')
    .slice(0, maxLength)
    .trim()
}

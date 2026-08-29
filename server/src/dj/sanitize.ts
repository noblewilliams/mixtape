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

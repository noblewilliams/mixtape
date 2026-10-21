import Anthropic from '@anthropic-ai/sdk'

export type LlmToolDef = {
  name: string
  description: string
  input_schema: { type: 'object'; properties: Record<string, unknown>; required?: string[]; additionalProperties?: boolean }
}

// Assistant content blocks. `thinking` is opaque — Sonnet 5 runs adaptive thinking by
// default and thinking blocks must be replayed back to the API verbatim (never
// reconstructed) when continuing on the same model, so we don't parse its shape here.
export type LlmAssistantBlock =
  | { type: 'text'; text: string }
  | { type: 'tool_use'; id: string; name: string; input: unknown }
  | { type: 'thinking'; [k: string]: unknown }

export type LlmMessage =
  | { role: 'user' | 'assistant'; content: string }
  | { role: 'user'; content: Array<{ type: 'tool_result'; tool_use_id: string; content: string }> }
  // Cacheable text blocks — used by curation's pool block (see dj/curate.ts) to
  // pin an ephemeral cache breakpoint under a large, otherwise-plain user turn.
  | { role: 'user'; content: Array<{ type: 'text'; text: string; cache_control?: { type: 'ephemeral' } }> }
  | { role: 'assistant'; content: LlmAssistantBlock[] }

export type LlmRequest = {
  system: string
  messages: LlmMessage[]
  tools: LlmToolDef[]
  maxTokens?: number
  effort?: 'low' | 'medium' | 'high'
}
export type LlmToolCall = { id: string; name: string; input: unknown }
export type LlmTurn = {
  text: string
  toolCalls: LlmToolCall[]
  raw: LlmAssistantBlock[] // full assistant content, for verbatim replay (includes thinking blocks)
  stopReason: string | null // 'max_tokens' must be detectable (curation truncation)
  // cacheReadInputTokens is null whenever the response carries no usage at
  // all (see `usage` itself going null below) — kept separate from `0` so a
  // caller logging cache effectiveness (Task 10) can distinguish "no usage
  // reported" from "usage reported, cache missed entirely".
  usage: { inputTokens: number; outputTokens: number; cacheReadInputTokens: number | null } | null
}
export type LlmClient = (req: LlmRequest) => Promise<LlmTurn>

export const DJ_MODEL = 'claude-sonnet-5'
const DEFAULT_MAX_TOKENS = 16000

// Thrown by anthropicLlm on any SDK failure. Callers (the agent loop) classify on
// this type alone and never import the SDK — deliberately excludes the SDK's own
// error message, which can echo request content (system prompt, user text, tool input).
export class LlmError extends Error {
  constructor(
    readonly detail: string,
    readonly status?: number,
  ) {
    super(`anthropic: ${detail}`)
    this.name = 'LlmError'
  }
}

// Shared by anthropicLlm and anthropicComplete — deliberately excludes the SDK's
// own error message (see LlmError's comment above). A status-less APIError (an SSE `error` event mid-stream, a dropped
// connection) carries the API's error type — e.g. overloaded_error — in
// `type` or its body; name it so logTurn shows more than "HTTP unknown".
function toLlmError(e: unknown): LlmError {
  if (e instanceof Anthropic.APIError) {
    const bodyType = (e.error as { error?: { type?: unknown } } | undefined)?.error?.type
    const errType = e.type ?? (typeof bodyType === 'string' ? bodyType : null)
    const detail = e.status === undefined && errType ? `HTTP unknown (${errType})` : `HTTP ${e.status ?? 'unknown'}`
    return new LlmError(detail, e.status)
  }
  return new LlmError(e instanceof Error ? e.name : typeof e)
}

// A minimal, tools-less "ask the model one thing, get text back" seam —
// deliberately separate from LlmClient/DJ_MODEL: callers that need a
// different model (e.g. session titling, see dj/title.ts) pass it per call,
// and a plain-text no-tools request never collides with curate()'s own
// no-tools convention (see dj/curate.ts, dj/loop.ts's makeFakeLlm fakes),
// which a caller sharing LlmClient for both would.
export type LlmComplete = (opts: {
  system: string
  prompt: string
  model: string
  maxTokens?: number
  // Forwarded to the SDK as a per-request timeout so a stalled upstream call
  // is actually cancelled rather than riding the client's default (60s ×
  // maxRetries 1, see buildAnthropic) — a caller racing this against other
  // work (see dj/title.ts, sessions.ts) needs a bound tighter than that.
  timeoutMs?: number
}) => Promise<string>

// Final shape both SDK paths resolve to — a non-streaming create's response, or
// a stream's finalMessage() (the SDK accumulates every content block, thinking
// blocks included with their signatures, plus stop_reason and usage).
type AnthropicMessage = {
  content: Anthropic.ContentBlock[]
  stop_reason: string | null
  usage: { input_tokens: number; output_tokens: number; cache_read_input_tokens?: number | null }
}

// Structural surfaces of the real SDK client — fakes `{ messages: { create } }` /
// `{ messages: { stream } }` in tests satisfy these directly, no `as never`
// needed in either direction.
type AnthropicClient = {
  messages: {
    create(body: Anthropic.MessageCreateParamsNonStreaming, options?: { timeout?: number }): Promise<AnthropicMessage>
  }
}
type AnthropicStreamingClient = {
  messages: {
    stream(
      body: Anthropic.MessageStreamParams,
      options?: { signal?: AbortSignal },
    ): { finalMessage(): Promise<AnthropicMessage> }
  }
}

// Always streams. The proven cause of the prod failure (2026-10-21, ~126s,
// "HTTP unknown"): called non-streaming, a long adaptive-thinking turn
// (curation runs up to 16k max_tokens) returns no headers until the model is
// done, so the SDK's 60s time-to-headers timeout fired, retried once
// (maxRetries 1, see buildAnthropic) and surfaced as APIConnectionTimeoutError.
// A stream returns headers at once, so that timeout no longer applies;
// finalMessage() resolves to the same Message shape create did, and rejects on
// any mid-stream error.
//
// Total deadline per call: the iOS client gives up at 120s
// (client/lib/data/dj/dj_api.dart), so a stalled stream must fail before that
// rather than spend tokens on a queue nobody will see.
export const LLM_CALL_DEADLINE_MS = 100_000

export function anthropicLlm(
  client: AnthropicStreamingClient,
  opts: { deadlineMs?: number } = {},
): LlmClient {
  const deadlineMs = opts.deadlineMs ?? LLM_CALL_DEADLINE_MS
  return async (req) => {
    let res: AnthropicMessage
    const signal = AbortSignal.timeout(deadlineMs)
    try {
      res = await client.messages
        .stream(
          {
            model: DJ_MODEL,
            max_tokens: req.maxTokens ?? DEFAULT_MAX_TOKENS,
            system: req.system,
            messages: req.messages as Anthropic.MessageParam[],
            tools: req.tools,
            ...(req.effort ? { output_config: { effort: req.effort } } : {}),
          },
          { signal },
        )
        .finalMessage()
    } catch (e) {
      // The SDK turns our deadline's abort into a status-less APIUserAbortError;
      // report it by the signal's own reason (a TimeoutError) instead.
      if (signal.aborted) {
        const reason: unknown = signal.reason
        throw new LlmError(reason instanceof Error ? reason.name : 'TimeoutError')
      }
      throw toLlmError(e)
    }
    const raw = res.content as LlmAssistantBlock[]
    const text = raw
      .filter((b): b is { type: 'text'; text: string } => b.type === 'text')
      .map((b) => b.text)
      .join('\n')
    const toolCalls = raw
      .filter((b): b is { type: 'tool_use'; id: string; name: string; input: unknown } => b.type === 'tool_use')
      .map((b) => ({ id: b.id, name: b.name, input: b.input }))
    return {
      text,
      toolCalls,
      raw,
      stopReason: res.stop_reason,
      usage: res.usage
        ? {
            inputTokens: res.usage.input_tokens,
            outputTokens: res.usage.output_tokens,
            cacheReadInputTokens: res.usage.cache_read_input_tokens ?? null,
          }
        : null,
    }
  }
}

// Text-only counterpart to anthropicLlm — no tools, no tool-loop bookkeeping,
// just `system` + a single user-turn prompt in, joined text blocks out. Same
// AnthropicClient structural type (and the same toLlmError wrapping), so it
// carries no separate credentials or client wiring.
export function anthropicComplete(client: AnthropicClient): LlmComplete {
  return async (opts) => {
    let res: AnthropicMessage
    try {
      res = await client.messages.create(
        {
          model: opts.model,
          max_tokens: opts.maxTokens ?? 300,
          system: opts.system,
          messages: [{ role: 'user', content: opts.prompt }],
        },
        // Actually cancels the upstream call at opts.timeoutMs rather than
        // letting it ride buildAnthropic's client-level default (60s ×
        // maxRetries 1) — see the LlmComplete type comment above.
        opts.timeoutMs !== undefined ? { timeout: opts.timeoutMs } : undefined,
      )
    } catch (e) {
      throw toLlmError(e)
    }
    return (res.content as LlmAssistantBlock[])
      .filter((b): b is { type: 'text'; text: string } => b.type === 'text')
      .map((b) => b.text)
      .join('\n')
  }
}

export function buildAnthropic(apiKey: string): Anthropic {
  // Chat turns run inside a Worker request — fail fast instead of the SDK default
  // (10 min timeout × up to 3 attempts), which would tie up the whole request.
  return new Anthropic({ apiKey, timeout: 60_000, maxRetries: 1 })
}

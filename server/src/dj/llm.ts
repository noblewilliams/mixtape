import Anthropic from '@anthropic-ai/sdk'

export type LlmToolDef = {
  name: string
  description: string
  input_schema: { type: 'object'; properties: Record<string, unknown>; required?: string[] }
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
  usage: { inputTokens: number; outputTokens: number } | null
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

// Structural surface of the real SDK client — a fake `{ messages: { create } }` in
// tests satisfies this directly, no `as never` needed in either direction.
type AnthropicClient = {
  messages: {
    create(body: Anthropic.MessageCreateParamsNonStreaming): Promise<{
      content: Anthropic.ContentBlock[]
      stop_reason: string | null
      usage: { input_tokens: number; output_tokens: number }
    }>
  }
}

export function anthropicLlm(client: AnthropicClient): LlmClient {
  return async (req) => {
    let res: Awaited<ReturnType<AnthropicClient['messages']['create']>>
    try {
      res = await client.messages.create({
        model: DJ_MODEL,
        max_tokens: req.maxTokens ?? DEFAULT_MAX_TOKENS,
        system: req.system,
        messages: req.messages as Anthropic.MessageParam[],
        tools: req.tools,
        ...(req.effort ? { output_config: { effort: req.effort } } : {}),
      })
    } catch (e) {
      throw new LlmError(
        e instanceof Anthropic.APIError ? `HTTP ${e.status ?? 'unknown'}` : e instanceof Error ? e.name : typeof e,
        e instanceof Anthropic.APIError ? e.status : undefined,
      )
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
      usage: res.usage ? { inputTokens: res.usage.input_tokens, outputTokens: res.usage.output_tokens } : null,
    }
  }
}

export function buildAnthropic(apiKey: string): Anthropic {
  // Chat turns run inside a Worker request — fail fast instead of the SDK default
  // (10 min timeout × up to 3 attempts), which would tie up the whole request.
  return new Anthropic({ apiKey, timeout: 60_000, maxRetries: 1 })
}

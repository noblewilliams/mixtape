import Anthropic from '@anthropic-ai/sdk'

export type LlmToolDef = { name: string; description: string; input_schema: Record<string, unknown> }
export type LlmMessage =
  | { role: 'user' | 'assistant'; content: string }
  | { role: 'user'; content: Array<{ type: 'tool_result'; tool_use_id: string; content: string }> }
  | { role: 'assistant'; content: Array<{ type: 'text'; text: string } | { type: 'tool_use'; id: string; name: string; input: unknown }> }
export type LlmRequest = { system: string; messages: LlmMessage[]; tools: LlmToolDef[] }
export type LlmToolCall = { id: string; name: string; input: unknown }
export type LlmTurn = { text: string; toolCalls: LlmToolCall[]; raw: unknown }
export type LlmClient = (req: LlmRequest) => Promise<LlmTurn>

export const DJ_MODEL = 'claude-sonnet-5'

// Narrow surface of the real SDK client — keeps the seam mockable with a fake
// `{ messages: { create } }` in tests without depending on the full Anthropic class shape.
type AnthropicClient = { messages: { create: Anthropic['messages']['create'] } }

export function anthropicLlm(client: AnthropicClient): LlmClient {
  return async (req) => {
    const res = await client.messages.create({
      model: DJ_MODEL,
      max_tokens: 4096,
      system: req.system,
      messages: req.messages as Anthropic.MessageParam[],
      tools: req.tools as Anthropic.Tool[],
    })
    const text = res.content
      .filter((b): b is Anthropic.TextBlock => b.type === 'text')
      .map((b) => b.text)
      .join('\n')
    const toolCalls = res.content
      .filter((b): b is Anthropic.ToolUseBlock => b.type === 'tool_use')
      .map((b) => ({ id: b.id, name: b.name, input: b.input }))
    return { text, toolCalls, raw: res.content }
  }
}

export function buildAnthropic(apiKey: string): Anthropic {
  return new Anthropic({ apiKey })
}

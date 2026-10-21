import { describe, it, expect } from 'vitest'
import Anthropic from '@anthropic-ai/sdk'
import { anthropicLlm, anthropicComplete, LlmError, LLM_CALL_DEADLINE_MS, type LlmTurn, type LlmRequest, type LlmMessage } from '../../src/dj/llm'

const baseReq: LlmRequest = { system: 's', messages: [], tools: [] }

// Fake of the SDK's `messages.stream(body).finalMessage()` — wraps a create-style
// responder so each test still reads as "this body in, this Message out". A
// throwing responder rejects finalMessage(), mirroring a mid-stream failure.
type FakeMessage = {
  content: Anthropic.ContentBlock[]
  stop_reason: string | null
  usage: { input_tokens: number; output_tokens: number; cache_read_input_tokens?: number | null }
}
function streamOf(respond: (body: Anthropic.MessageStreamParams) => Promise<FakeMessage>) {
  return (body: Anthropic.MessageStreamParams, _options?: { signal?: AbortSignal }) => ({
    finalMessage: () => respond(body),
  })
}

function sse(events: Array<[string, unknown]>): string {
  return events.map(([event, data]) => `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`).join('')
}

describe('anthropicLlm', () => {
  it('adapts anthropic responses into LlmTurn', async () => {
    const fakeCreate = async () => ({
      content: [
        { type: 'text', text: 'here you go' },
        { type: 'tool_use', id: 'tu_1', name: 'generate_queue', input: { themes: 'rain' } },
      ] as Anthropic.ContentBlock[],
      stop_reason: 'tool_use',
      usage: { input_tokens: 100, output_tokens: 20 },
    })
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    const turn: LlmTurn = await llm(baseReq)
    expect(turn.text).toBe('here you go')
    expect(turn.toolCalls).toEqual([{ id: 'tu_1', name: 'generate_queue', input: { themes: 'rain' } }])
  })

  it('yields no tool calls and joins multiple text blocks when the response has none', async () => {
    const fakeCreate = async () => ({
      content: [
        { type: 'text', text: 'first line' },
        { type: 'text', text: 'second line' },
      ] as Anthropic.ContentBlock[],
      stop_reason: 'end_turn',
      usage: { input_tokens: 10, output_tokens: 5 },
    })
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    const turn: LlmTurn = await llm(baseReq)
    expect(turn.toolCalls).toEqual([])
    expect(turn.text).toBe('first line\nsecond line')
  })

  it('maps stopReason and usage through', async () => {
    const fakeCreate = async () => ({
      content: [{ type: 'text', text: 'truncated' }] as Anthropic.ContentBlock[],
      stop_reason: 'max_tokens',
      usage: { input_tokens: 4096, output_tokens: 16000, cache_read_input_tokens: 2048 },
    })
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    const turn = await llm(baseReq)
    expect(turn.stopReason).toBe('max_tokens')
    expect(turn.usage).toEqual({ inputTokens: 4096, outputTokens: 16000, cacheReadInputTokens: 2048 })
  })

  it('defaults cacheReadInputTokens to null when the SDK response omits it', async () => {
    const fakeCreate = async () => ({
      content: [{ type: 'text', text: 'ok' }] as Anthropic.ContentBlock[],
      stop_reason: 'end_turn',
      usage: { input_tokens: 1, output_tokens: 1 },
    })
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    const turn = await llm(baseReq)
    expect(turn.usage).toEqual({ inputTokens: 1, outputTokens: 1, cacheReadInputTokens: null })
  })

  it('carries a thinking block through raw, excluded from text and toolCalls', async () => {
    const thinkingBlock = { type: 'thinking', thinking: 'reasoning about the queue', signature: 'sig123' }
    const fakeCreate = async () => ({
      content: [
        thinkingBlock,
        { type: 'text', text: 'the answer' },
      ] as unknown as Anthropic.ContentBlock[],
      stop_reason: 'end_turn',
      usage: { input_tokens: 10, output_tokens: 5 },
    })
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    const turn = await llm(baseReq)
    expect(turn.raw).toEqual([thinkingBlock, { type: 'text', text: 'the answer' }])
    expect(turn.text).toBe('the answer')
    expect(turn.toolCalls).toEqual([])
  })

  it('produces empty text with no text block in raw on a tool-only turn (documents: replay raw, never reconstruct)', async () => {
    const fakeCreate = async () => ({
      content: [
        { type: 'tool_use', id: 'tu_2', name: 'edit_queue', input: { ops: [] } },
      ] as Anthropic.ContentBlock[],
      stop_reason: 'tool_use',
      usage: { input_tokens: 10, output_tokens: 5 },
    })
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    const turn = await llm(baseReq)
    expect(turn.text).toBe('')
    expect(turn.raw.some((b) => b.type === 'text')).toBe(false)
    expect(turn.raw).toEqual([{ type: 'tool_use', id: 'tu_2', name: 'edit_queue', input: { ops: [] } }])
  })

  it('wraps a thrown APIError into LlmError, carrying status and no request content', async () => {
    const apiError = new Anthropic.APIError(429, { error: { message: 'contains request text: rainy drive' } }, 'rate limited', new Headers())
    const fakeCreate = async () => {
      throw apiError
    }
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    expect.assertions(4)
    try {
      await llm(baseReq)
    } catch (e) {
      expect(e).toBeInstanceOf(LlmError)
      const err = e as LlmError
      expect(err.status).toBe(429)
      expect(err.message).not.toContain('rainy drive')
      expect(err.message).not.toContain('rate limited')
    }
  })

  it('wraps a thrown non-APIError into LlmError with no status', async () => {
    const fakeCreate = async () => {
      throw new Error('boom: leaked system prompt text')
    }
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    expect.assertions(3)
    try {
      await llm(baseReq)
    } catch (e) {
      expect(e).toBeInstanceOf(LlmError)
      const err = e as LlmError
      expect(err.status).toBeUndefined()
      expect(err.message).not.toContain('leaked system prompt text')
    }
  })

  it('forwards maxTokens and effort into the stream body', async () => {
    let captured: Anthropic.MessageStreamParams | undefined
    const fakeCreate = async (body: Anthropic.MessageStreamParams) => {
      captured = body
      return {
        content: [{ type: 'text', text: 'ok' }] as Anthropic.ContentBlock[],
        stop_reason: 'end_turn',
        usage: { input_tokens: 1, output_tokens: 1 },
      }
    }
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    await llm({ ...baseReq, maxTokens: 500, effort: 'low' })
    expect(captured?.max_tokens).toBe(500)
    expect(captured?.output_config).toEqual({ effort: 'low' })
  })

  it('passes a user message built from cacheable text content blocks straight through to the SDK', async () => {
    let captured: Anthropic.MessageStreamParams | undefined
    const fakeCreate = async (body: Anthropic.MessageStreamParams) => {
      captured = body
      return {
        content: [{ type: 'text', text: 'ok' }] as Anthropic.ContentBlock[],
        stop_reason: 'end_turn',
        usage: { input_tokens: 1, output_tokens: 1 },
      }
    }
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    const userMsg: LlmMessage = {
      role: 'user',
      content: [
        { type: 'text', text: 'pool block', cache_control: { type: 'ephemeral' } },
        { type: 'text', text: 'intent block' },
      ],
    }
    await llm({ ...baseReq, messages: [userMsg] })
    expect(captured?.messages).toEqual([
      {
        role: 'user',
        content: [
          { type: 'text', text: 'pool block', cache_control: { type: 'ephemeral' } },
          { type: 'text', text: 'intent block' },
        ],
      },
    ])
  })

  it('defaults maxTokens and omits output_config when effort is unset', async () => {
    let captured: Anthropic.MessageStreamParams | undefined
    const fakeCreate = async (body: Anthropic.MessageStreamParams) => {
      captured = body
      return {
        content: [{ type: 'text', text: 'ok' }] as Anthropic.ContentBlock[],
        stop_reason: 'end_turn',
        usage: { input_tokens: 1, output_tokens: 1 },
      }
    }
    const llm = anthropicLlm({ messages: { stream: streamOf(fakeCreate) } })
    await llm(baseReq)
    expect(captured?.max_tokens).toBe(16000)
    expect(captured?.output_config).toBeUndefined()
  })

  it('sends the stream exactly the params the non-streaming create used to receive', async () => {
    let captured: unknown
    const llm = anthropicLlm({
      messages: {
        stream: streamOf(async (body) => {
          captured = body
          return { content: [], stop_reason: 'end_turn', usage: { input_tokens: 1, output_tokens: 1 } }
        }),
      },
    })
    const tool = {
      name: 'generate_queue',
      description: 'd',
      input_schema: { type: 'object' as const, properties: { themes: { type: 'string' } }, required: ['themes'] },
    }
    const messages: LlmMessage[] = [
      { role: 'user', content: 'rainy drive' },
      { role: 'assistant', content: [{ type: 'thinking', thinking: 't', signature: 'sig' }, { type: 'text', text: 'ok' }] },
    ]
    await llm({ system: 'sys', messages, tools: [tool], maxTokens: 9000, effort: 'medium' })
    expect(JSON.stringify(captured)).toBe(
      JSON.stringify({
        model: 'claude-sonnet-5',
        max_tokens: 9000,
        system: 'sys',
        messages,
        tools: [tool],
        output_config: { effort: 'medium' },
      }),
    )
    expect(captured).not.toHaveProperty('stream')
  })

  it('builds text, toolCalls, raw (with thinking) and usage from the final streamed message', async () => {
    const thinkingBlock = { type: 'thinking', thinking: 'weighing tempo', signature: 'sig9' }
    const llm = anthropicLlm({
      messages: {
        stream: streamOf(async () => ({
          content: [
            thinkingBlock,
            { type: 'text', text: 'queued' },
            { type: 'tool_use', id: 'tu_9', name: 'generate_queue', input: { themes: 'dusk' } },
          ] as unknown as Anthropic.ContentBlock[],
          stop_reason: 'tool_use',
          usage: { input_tokens: 50, output_tokens: 7, cache_read_input_tokens: 40 },
        })),
      },
    })
    const turn = await llm(baseReq)
    expect(turn.raw[0]).toEqual(thinkingBlock)
    expect(turn.text).toBe('queued')
    expect(turn.toolCalls).toEqual([{ id: 'tu_9', name: 'generate_queue', input: { themes: 'dusk' } }])
    expect(turn.stopReason).toBe('tool_use')
    expect(turn.usage).toEqual({ inputTokens: 50, outputTokens: 7, cacheReadInputTokens: 40 })
  })

  it('maps a status-less APIConnectionError to LlmError detail "HTTP unknown" with no status', async () => {
    const llm = anthropicLlm({
      messages: {
        stream: streamOf(async () => {
          throw new Anthropic.APIConnectionError({ message: 'socket closed mid-stream: rainy drive' })
        }),
      },
    })
    expect.assertions(4)
    try {
      await llm(baseReq)
    } catch (e) {
      expect(e).toBeInstanceOf(LlmError)
      const err = e as LlmError
      expect(err.status).toBeUndefined()
      expect(err.detail).toBe('HTTP unknown')
      expect(err.message).not.toContain('rainy drive')
    }
  })

  it('maps a synchronous throw from stream() itself to LlmError', async () => {
    const llm = anthropicLlm({
      messages: {
        stream: () => {
          throw new Anthropic.APIError(529, undefined, 'overloaded', new Headers())
        },
      },
    })
    await expect(llm(baseReq)).rejects.toMatchObject({ name: 'LlmError', status: 529 })
  })
  it('names the API error type in the detail for a status-less mid-stream SSE error', async () => {
    const llm = anthropicLlm({
      messages: {
        stream: streamOf(async () => {
          throw new Anthropic.APIError(undefined, { error: { type: 'overloaded_error' } }, undefined, new Headers())
        }),
      },
    })
    const err = await llm(baseReq).catch((e: unknown) => e)
    expect(err).toBeInstanceOf(LlmError)
    expect((err as LlmError).detail).toContain('overloaded_error')
    expect((err as LlmError).status).toBeUndefined()
  })

  it('maps a raw fetch TypeError to detail "TypeError"', async () => {
    const llm = anthropicLlm({
      messages: {
        stream: streamOf(async () => {
          throw new TypeError('Network connection lost')
        }),
      },
    })
    const err = await llm(baseReq).catch((e: unknown) => e)
    expect(err).toBeInstanceOf(LlmError)
    expect((err as LlmError).detail).toBe('TypeError')
  })

  it('caps the whole call below the iOS client 120s give-up', () => {
    expect(LLM_CALL_DEADLINE_MS).toBe(100_000)
  })

  it('aborts a stalled stream at the deadline and surfaces a timeout LlmError', async () => {
    let seenSignal: AbortSignal | undefined
    const llm = anthropicLlm(
      {
        messages: {
          stream: (_body, options) => {
            seenSignal = options?.signal
            return {
              // Never resolves on its own — only the deadline's abort ends it,
              // the way the SDK rejects finalMessage() when its signal fires.
              finalMessage: () =>
                new Promise<never>((_resolve, reject) => {
                  options?.signal?.addEventListener('abort', () => reject(new Anthropic.APIUserAbortError()))
                }),
            }
          },
        },
      },
      { deadlineMs: 20 },
    )
    const err = await llm(baseReq).catch((e: unknown) => e)
    expect(seenSignal?.aborted).toBe(true)
    expect(err).toBeInstanceOf(LlmError)
    expect((err as LlmError).detail).toMatch(/Timeout|Abort/)
    expect((err as LlmError).status).toBeUndefined()
  })

  it('accumulates a real SDK SSE stream (thinking + signature, tool_use JSON, max_tokens, usage)', async () => {
    const body = sse([
      ['message_start', {
        type: 'message_start',
        message: {
          id: 'msg_1', type: 'message', role: 'assistant', model: 'claude-sonnet-5', content: [],
          stop_reason: null, stop_sequence: null,
          usage: { input_tokens: 1200, output_tokens: 1, cache_read_input_tokens: 800 },
        },
      }],
      ['content_block_start', { type: 'content_block_start', index: 0, content_block: { type: 'thinking', thinking: '', signature: '' } }],
      ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'slow build, ' } }],
      ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'thinking_delta', thinking: 'then lift' } }],
      ['content_block_delta', { type: 'content_block_delta', index: 0, delta: { type: 'signature_delta', signature: 'sigXYZ' } }],
      ['content_block_stop', { type: 'content_block_stop', index: 0 }],
      ['content_block_start', { type: 'content_block_start', index: 1, content_block: { type: 'tool_use', id: 'tu_s', name: 'generate_queue', input: {} } }],
      ['content_block_delta', { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '{"themes":' } }],
      ['content_block_delta', { type: 'content_block_delta', index: 1, delta: { type: 'input_json_delta', partial_json: '"rain"}' } }],
      ['content_block_stop', { type: 'content_block_stop', index: 1 }],
      ['message_delta', { type: 'message_delta', delta: { stop_reason: 'max_tokens', stop_sequence: null }, usage: { output_tokens: 9000 } }],
      ['message_stop', { type: 'message_stop' }],
    ])
    const fakeFetch = async () =>
      new Response(body, { status: 200, headers: { 'content-type': 'text/event-stream' } })
    const llm = anthropicLlm(new Anthropic({ apiKey: 'x', fetch: fakeFetch, maxRetries: 0 }))
    const turn = await llm(baseReq)
    expect(turn.raw[0]).toEqual({ type: 'thinking', thinking: 'slow build, then lift', signature: 'sigXYZ' })
    expect(turn.toolCalls[0]?.input).toEqual({ themes: 'rain' })
    expect(turn.stopReason).toBe('max_tokens')
    expect(turn.usage).toEqual({ inputTokens: 1200, outputTokens: 9000, cacheReadInputTokens: 800 })
  })
})

describe('anthropicComplete', () => {
  it('joins text blocks into a single string and omits tools from the request body', async () => {
    let captured: Anthropic.MessageCreateParamsNonStreaming | undefined
    const fakeCreate = async (body: Anthropic.MessageCreateParamsNonStreaming) => {
      captured = body
      return {
        content: [
          { type: 'text', text: 'first line' },
          { type: 'text', text: 'second line' },
        ] as Anthropic.ContentBlock[],
        stop_reason: 'end_turn',
        usage: { input_tokens: 1, output_tokens: 1 },
      }
    }
    const complete = anthropicComplete({ messages: { create: fakeCreate } })
    const text = await complete({ system: 's', prompt: 'p', model: 'm' })
    expect(text).toBe('first line\nsecond line')
    expect(captured).not.toHaveProperty('tools')
  })

  it('forwards timeoutMs as a per-request timeout option to the SDK call, actually bounding the upstream request', async () => {
    let capturedOptions: { timeout?: number } | undefined
    const fakeCreate = async (_body: Anthropic.MessageCreateParamsNonStreaming, options?: { timeout?: number }) => {
      capturedOptions = options
      return {
        content: [{ type: 'text', text: 'ok' }] as Anthropic.ContentBlock[],
        stop_reason: 'end_turn',
        usage: { input_tokens: 1, output_tokens: 1 },
      }
    }
    const complete = anthropicComplete({ messages: { create: fakeCreate } })
    await complete({ system: 's', prompt: 'p', model: 'm', timeoutMs: 5000 })
    expect(capturedOptions).toEqual({ timeout: 5000 })
  })

  it('omits the timeout option entirely when timeoutMs is not passed', async () => {
    let capturedOptions: { timeout?: number } | undefined
    const fakeCreate = async (_body: Anthropic.MessageCreateParamsNonStreaming, options?: { timeout?: number }) => {
      capturedOptions = options
      return {
        content: [{ type: 'text', text: 'ok' }] as Anthropic.ContentBlock[],
        stop_reason: 'end_turn',
        usage: { input_tokens: 1, output_tokens: 1 },
      }
    }
    const complete = anthropicComplete({ messages: { create: fakeCreate } })
    await complete({ system: 's', prompt: 'p', model: 'm' })
    expect(capturedOptions).toBeUndefined()
  })

  it('wraps a thrown error into LlmError, excluding the SDK error message', async () => {
    const fakeCreate = async () => {
      throw new Error('boom: leaked system prompt text')
    }
    const complete = anthropicComplete({ messages: { create: fakeCreate } })
    expect.assertions(2)
    try {
      await complete({ system: 's', prompt: 'p', model: 'm' })
    } catch (e) {
      expect(e).toBeInstanceOf(LlmError)
      expect((e as LlmError).message).not.toContain('leaked system prompt text')
    }
  })
})

import { describe, it, expect } from 'vitest'
import Anthropic from '@anthropic-ai/sdk'
import { anthropicLlm, LlmError, type LlmTurn, type LlmRequest, type LlmMessage } from '../../src/dj/llm'

const baseReq: LlmRequest = { system: 's', messages: [], tools: [] }

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
    const llm = anthropicLlm({ messages: { create: fakeCreate } })
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
    const llm = anthropicLlm({ messages: { create: fakeCreate } })
    const turn: LlmTurn = await llm(baseReq)
    expect(turn.toolCalls).toEqual([])
    expect(turn.text).toBe('first line\nsecond line')
  })

  it('maps stopReason and usage through', async () => {
    const fakeCreate = async () => ({
      content: [{ type: 'text', text: 'truncated' }] as Anthropic.ContentBlock[],
      stop_reason: 'max_tokens',
      usage: { input_tokens: 4096, output_tokens: 16000 },
    })
    const llm = anthropicLlm({ messages: { create: fakeCreate } })
    const turn = await llm(baseReq)
    expect(turn.stopReason).toBe('max_tokens')
    expect(turn.usage).toEqual({ inputTokens: 4096, outputTokens: 16000 })
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
    const llm = anthropicLlm({ messages: { create: fakeCreate } })
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
    const llm = anthropicLlm({ messages: { create: fakeCreate } })
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
    const llm = anthropicLlm({ messages: { create: fakeCreate } })
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
    const llm = anthropicLlm({ messages: { create: fakeCreate } })
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

  it('forwards maxTokens and effort into the create body', async () => {
    let captured: Anthropic.MessageCreateParamsNonStreaming | undefined
    const fakeCreate = async (body: Anthropic.MessageCreateParamsNonStreaming) => {
      captured = body
      return {
        content: [{ type: 'text', text: 'ok' }] as Anthropic.ContentBlock[],
        stop_reason: 'end_turn',
        usage: { input_tokens: 1, output_tokens: 1 },
      }
    }
    const llm = anthropicLlm({ messages: { create: fakeCreate } })
    await llm({ ...baseReq, maxTokens: 500, effort: 'low' })
    expect(captured?.max_tokens).toBe(500)
    expect(captured?.output_config).toEqual({ effort: 'low' })
  })

  it('passes a user message built from cacheable text content blocks straight through to the SDK', async () => {
    let captured: Anthropic.MessageCreateParamsNonStreaming | undefined
    const fakeCreate = async (body: Anthropic.MessageCreateParamsNonStreaming) => {
      captured = body
      return {
        content: [{ type: 'text', text: 'ok' }] as Anthropic.ContentBlock[],
        stop_reason: 'end_turn',
        usage: { input_tokens: 1, output_tokens: 1 },
      }
    }
    const llm = anthropicLlm({ messages: { create: fakeCreate } })
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
    let captured: Anthropic.MessageCreateParamsNonStreaming | undefined
    const fakeCreate = async (body: Anthropic.MessageCreateParamsNonStreaming) => {
      captured = body
      return {
        content: [{ type: 'text', text: 'ok' }] as Anthropic.ContentBlock[],
        stop_reason: 'end_turn',
        usage: { input_tokens: 1, output_tokens: 1 },
      }
    }
    const llm = anthropicLlm({ messages: { create: fakeCreate } })
    await llm(baseReq)
    expect(captured?.max_tokens).toBe(16000)
    expect(captured?.output_config).toBeUndefined()
  })
})

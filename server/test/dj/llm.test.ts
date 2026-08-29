import { describe, it, expect } from 'vitest'
import { anthropicLlm, type LlmTurn } from '../../src/dj/llm'

describe('anthropicLlm', () => {
  it('adapts anthropic responses into LlmTurn', async () => {
    const fakeCreate = async (req: unknown) => ({
      content: [
        { type: 'text', text: 'here you go' },
        { type: 'tool_use', id: 'tu_1', name: 'generate_queue', input: { themes: 'rain' } },
      ],
      stop_reason: 'tool_use',
    })
    const llm = anthropicLlm({ messages: { create: fakeCreate } } as never)
    const turn: LlmTurn = await llm({ system: 's', messages: [], tools: [] })
    expect(turn.text).toBe('here you go')
    expect(turn.toolCalls).toEqual([{ id: 'tu_1', name: 'generate_queue', input: { themes: 'rain' } }])
  })

  it('yields no tool calls and joins multiple text blocks when the response has none', async () => {
    const fakeCreate = async (req: unknown) => ({
      content: [
        { type: 'text', text: 'first line' },
        { type: 'text', text: 'second line' },
      ],
      stop_reason: 'end_turn',
    })
    const llm = anthropicLlm({ messages: { create: fakeCreate } } as never)
    const turn: LlmTurn = await llm({ system: 's', messages: [], tools: [] })
    expect(turn.toolCalls).toEqual([])
    expect(turn.text).toBe('first line\nsecond line')
  })
})

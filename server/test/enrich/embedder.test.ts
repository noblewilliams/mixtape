import { describe, it, expect } from 'vitest'
import { workersAiEmbedder } from '../../src/enrich/embedder'

const INPUT = 'some very secret lyric text that must never leak'

describe('workersAiEmbedder', () => {
  it('returns data[0] on the happy path', async () => {
    const embed = workersAiEmbedder({ run: async () => ({ data: [[1, 2, 3]] }) })
    expect(await embed(INPUT)).toEqual([1, 2, 3])
  })

  it('truncates input to 6000 chars', async () => {
    let seen: string[] | undefined
    const embed = workersAiEmbedder({
      run: async (_model, input) => {
        seen = input.text
        return { data: [[1]] }
      },
    })
    await embed('a'.repeat(7000))
    expect(seen?.[0]).toHaveLength(6000)
  })

  it('never leaks the input into the error when the response shape is unexpected', async () => {
    const embed = workersAiEmbedder({ run: async () => ({}) })
    let error: unknown
    try {
      await embed(INPUT)
      throw new Error('expected embed to reject')
    } catch (e) {
      error = e
    }
    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).not.toContain(INPUT)
  })

  it('never leaks the input into the error when the binding itself throws', async () => {
    const embed = workersAiEmbedder({
      run: async () => {
        throw new Error(`binding exploded on input: ${INPUT}`)
      },
    })
    let error: unknown
    try {
      await embed(INPUT)
      throw new Error('expected embed to reject')
    } catch (e) {
      error = e
    }
    expect(error).toBeInstanceOf(Error)
    expect((error as Error).message).not.toContain(INPUT)
  })
})

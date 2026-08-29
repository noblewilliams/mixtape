// Lyric text passes through here transiently and is never stored or logged.
export type Embedder = (text: string) => Promise<number[]>

type AiBinding = { run(model: string, input: { text: string[] }): Promise<unknown> }

export function workersAiEmbedder(ai: AiBinding): Embedder {
  return async (text) => {
    const out = (await ai.run('@cf/baai/bge-m3', { text: [text.slice(0, 6000)] })) as {
      data?: number[][]
    }
    const vec = out?.data?.[0]
    // Error text deliberately excludes the input — never leak lyrics into logs.
    if (!vec || !vec.length) throw new Error(`embedder: unexpected AI response shape (keys: ${Object.keys(out ?? {}).join(',')})`)
    return vec
  }
}

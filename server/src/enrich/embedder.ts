// bge-m3's output width — shared by the pool's embedding-shape guard (dj/pool.ts)
// and track_meanings.embedding's vector(1024) column (db/schema.ts).
export const EMBEDDING_DIMENSIONS = 1024

// Lyric text passes through here transiently and is never stored or logged.
export type Embedder = (text: string) => Promise<number[]>

type AiBinding = { run(model: string, input: { text: string[] }): Promise<unknown> }

export function workersAiEmbedder(ai: AiBinding): Embedder {
  return async (text) => {
    let out: { data?: number[][] }
    try {
      out = (await ai.run('@cf/baai/bge-m3', { text: [text.slice(0, 6000)] })) as { data?: number[][] }
    } catch (e) {
      // Never rethrow the binding's error verbatim — it may echo the input payload.
      throw new Error(`embedder: AI binding failed (${e instanceof Error ? e.name : typeof e})`)
    }
    const vec = out?.data?.[0]
    // Error text deliberately excludes the input — never leak lyrics into logs.
    if (!vec || !vec.length) throw new Error(`embedder: unexpected AI response shape (keys: ${Object.keys(out ?? {}).join(',')})`)
    return vec
  }
}

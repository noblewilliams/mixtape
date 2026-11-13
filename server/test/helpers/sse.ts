// Reads a streamed turn (spec 2026-11-13 dj-turn-steps, "Wire contract") the
// way the clients count events: an event exists only once its blank line has
// arrived. Throws on any framing the contract does not allow, so every test
// that reads a stream also checks that every event, the last included, ends
// with "\n\n" and carries one data line of JSON.

export type SseEvent = { event: string; data: unknown; raw: string } | { comment: string }

export function parseSse(text: string): SseEvent[] {
  if (!text.endsWith('\n\n')) throw new Error(`stream does not end with a blank line: ${JSON.stringify(text.slice(-40))}`)
  const blocks = text.slice(0, -2).split('\n\n')
  return blocks.map((block) => {
    const lines = block.split('\n')
    if (lines.length === 1 && lines[0].startsWith(':')) return { comment: lines[0].slice(1).trim() }
    if (lines.length !== 2 || !lines[0].startsWith('event: ') || !lines[1].startsWith('data: ')) {
      throw new Error(`malformed event: ${JSON.stringify(block)}`)
    }
    const raw = lines[1].slice('data: '.length)
    return { event: lines[0].slice('event: '.length), data: JSON.parse(raw), raw }
  })
}

export function eventsOnly(events: SseEvent[]): Array<{ event: string; data: unknown; raw: string }> {
  return events.flatMap((e) => ('event' in e ? [e] : []))
}

export async function readSse(res: Response): Promise<SseEvent[]> {
  return parseSse(await res.text())
}

// Reads chunks until `count` complete events (comments included) arrived,
// leaving the rest of the stream unread.
export async function readEvents(reader: ReadableStreamDefaultReader<Uint8Array>, count: number): Promise<SseEvent[]> {
  const decoder = new TextDecoder()
  let text = ''
  while ((text.match(/\n\n/g) ?? []).length < count) {
    const { value, done } = await reader.read()
    if (done) break
    text += decoder.decode(value, { stream: true })
  }
  const complete = text.slice(0, text.lastIndexOf('\n\n') + 2)
  return parseSse(complete)
}

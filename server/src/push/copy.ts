import { sanitizeTitleText } from '../dj/sanitize'

export type PushCopy = { title: string; body: string }

// Spec "APNs from Workers" → Payload. The body is only ever the mix's title
// (or a fixed line): never lyrics, songs, the prompt or the DJ's reply.
export function readyCopy(mixTitle: string | null | undefined): PushCopy {
  const body = sanitizeTitleText(mixTitle ?? '', 40)
  return { title: 'Your mix is ready', body: body || 'Tap to play it.' }
}

export const FAILED_LINES: readonly PushCopy[] = [
  { title: 'Oops, the tape got tangled', body: 'Tap to try again.' },
  { title: 'Oops, the needle skipped', body: 'Give it another spin?' },
  { title: 'Oops, wobbly cassette', body: 'Tap to have another go.' },
]

// The seed is the turn id, so a turn's retried push reads the same line.
export function failedCopy(seed: string): PushCopy {
  return { ...FAILED_LINES[fnv1a(seed) % FAILED_LINES.length]! }
}

function fnv1a(text: string): number {
  let hash = 0x811c9dc5
  for (let i = 0; i < text.length; i += 1) {
    hash ^= text.charCodeAt(i)
    hash = Math.imul(hash, 0x01000193)
  }
  return hash >>> 0
}

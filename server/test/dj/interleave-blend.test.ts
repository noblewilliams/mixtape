import { describe, it, expect } from 'vitest'
import { interleaveBlend } from '../../src/dj/loop'

describe('interleaveBlend', () => {
  const c = ['c0', 'c1', 'c2', 'c3', 'c4', 'c5']

  it('spreads half proposed evenly, never side by side', () => {
    expect(interleaveBlend(c, ['p0', 'p1', 'p2'], 6)).toEqual(['c0', 'p0', 'c1', 'p1', 'c2', 'p2'])
  })

  it('a short proposal share leaves the rest to the catalogue, in its order', () => {
    expect(interleaveBlend(c, ['p0'], 6)).toEqual(['c0', 'c1', 'c2', 'c3', 'c4', 'p0'])
  })

  it('a short catalogue keeps every song both sides have, never past the total', () => {
    expect(interleaveBlend(['c0', 'c1'], ['p0', 'p1', 'p2'], 6)).toEqual(['c0', 'p0', 'c1', 'p1', 'p2'])
    expect(interleaveBlend(['c0', 'c1'], ['p0', 'p1', 'p2'], 3)).toEqual(['p0', 'p1', 'p2'])
  })

  it('no proposals is the catalogue cut to the total', () => {
    expect(interleaveBlend(c, [], 4)).toEqual(['c0', 'c1', 'c2', 'c3'])
  })
})

// Plan 2026-11-16 propose-first, S9: with an energy arc, the proposed songs
// take the same slots the even spread gives them, each placed where its
// energy fits the arc's curve. Curated songs never move.
describe('interleaveBlend along an energy arc', () => {
  type Song = { id: string; energy: number | null }
  const cur = (n: number): Song[] => Array.from({ length: n }, (_, i) => ({ id: `c${i}`, energy: 0.5 }))
  const prop = (energies: (number | null)[]): Song[] => energies.map((energy, i) => ({ id: `p${i}`, energy }))
  const energyOf = (s: Song) => s.energy
  const ids = (songs: Song[]) => songs.map((s) => s.id)
  const proposedIn = (songs: Song[]) => songs.filter((s) => s.id.startsWith('p'))
  const even = (curated: Song[], proposed: Song[], total: number) => interleaveBlend(curated, proposed, total)

  // Same length, same curated songs in the same places, same proposed slots.
  function expectSameShape(out: Song[], curated: Song[], proposed: Song[], total: number) {
    const base = even(curated, proposed, total)
    expect(out).toHaveLength(base.length)
    base.forEach((s, i) => {
      if (s.id.startsWith('c')) expect(out[i]).toBe(s)
      else expect(out[i].id.startsWith('p')).toBe(true)
    })
    expect(new Set(ids(proposedIn(out)))).toEqual(new Set(ids(proposedIn(base))))
  }

  it('rise puts low-energy proposals early and high late', () => {
    const curated = cur(6)
    const proposed = prop([0.9, 0.2, 0.6, 0.4, 0.8, 0.1])
    const out = interleaveBlend(curated, proposed, 12, { energyArc: 'rise', energyOf })
    expectSameShape(out, curated, proposed, 12)
    expect(proposedIn(out).map((s) => s.energy)).toEqual([0.1, 0.2, 0.4, 0.6, 0.8, 0.9])
  })

  it('fall puts high-energy proposals early and low late', () => {
    const curated = cur(6)
    const proposed = prop([0.9, 0.2, 0.6, 0.4, 0.8, 0.1])
    const out = interleaveBlend(curated, proposed, 12, { energyArc: 'fall', energyOf })
    expectSameShape(out, curated, proposed, 12)
    expect(proposedIn(out).map((s) => s.energy)).toEqual([0.9, 0.8, 0.6, 0.4, 0.2, 0.1])
  })

  it('arc puts the highest-energy proposal near the middle, low ones at the ends', () => {
    const curated = cur(5)
    const proposed = prop([0.9, 0.1, 0.5, 0.2, 0.6])
    const out = interleaveBlend(curated, proposed, 10, { energyArc: 'arc', energyOf })
    expectSameShape(out, curated, proposed, 10)
    const peak = out.findIndex((s) => s.energy === 0.9)
    expect(Math.abs(peak - (out.length - 1) / 2)).toBeLessThanOrEqual(1.5)
    const placed = proposedIn(out).map((s) => s.energy)
    expect([placed[0], placed.at(-1)].sort()).toEqual([0.1, 0.2])
  })

  it('steady, no arc, or too few known energies is the even spread', () => {
    const curated = cur(6)
    const proposed = prop([0.9, 0.2, 0.6, 0.4, 0.8, 0.1])
    const base = even(curated, proposed, 12)
    expect(interleaveBlend(curated, proposed, 12, { energyArc: 'steady', energyOf })).toEqual(base)
    expect(interleaveBlend(curated, proposed, 12, { energyOf })).toEqual(base)
    expect(interleaveBlend(curated, proposed, 12, {})).toEqual(base)
    // Three of six known is under 2/3.
    const sparse = prop([0.9, null, 0.6, null, null, 0.1])
    expect(interleaveBlend(curated, sparse, 12, { energyArc: 'rise', energyOf })).toEqual(even(curated, sparse, 12))
    // Out-of-range values count as unknown.
    const bad = prop([0.9, 7, 0.6, Number.NaN, -1, 0.1])
    expect(interleaveBlend(curated, bad, 12, { energyArc: 'rise', energyOf })).toEqual(even(curated, bad, 12))
  })

  it('curated relative order is kept, whatever their own energies', () => {
    const curated: Song[] = [0.9, 0.1, 0.7, 0.3].map((energy, i) => ({ id: `c${i}`, energy }))
    const proposed = prop([0.8, 0.3, 0.5, 0.1])
    const out = interleaveBlend(curated, proposed, 8, { energyArc: 'rise', energyOf })
    expect(ids(out.filter((s) => s.id.startsWith('c')))).toEqual(['c0', 'c1', 'c2', 'c3'])
    expectSameShape(out, curated, proposed, 8)
  })

  it('length and counts follow the even spread when either side is short or cut', () => {
    const proposed = prop([0.9, 0.2, 0.6, 0.4, 0.8])
    for (const [curated, total] of [[cur(2), 6], [cur(6), 6], [cur(2), 3], [cur(0), 4]] as const) {
      const out = interleaveBlend(curated, proposed, total, { energyArc: 'rise', energyOf })
      expectSameShape(out, curated, proposed, total)
    }
  })

  it('unknown-energy proposals fill the slots left over, in their original order', () => {
    const curated = cur(6)
    // Four of six known: p1 and p4 are unknown.
    const proposed = prop([0.9, null, 0.1, 0.5, null, 0.3])
    const out = interleaveBlend(curated, proposed, 12, { energyArc: 'rise', energyOf })
    expectSameShape(out, curated, proposed, 12)
    const placed = proposedIn(out)
    const known = placed.filter((s) => s.energy !== null).map((s) => s.energy)
    expect(known).toEqual([0.1, 0.3, 0.5, 0.9])
    expect(placed.filter((s) => s.energy === null).map((s) => s.id)).toEqual(['p1', 'p4'])
  })
})

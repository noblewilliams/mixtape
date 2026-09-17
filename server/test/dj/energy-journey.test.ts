import { expect, it } from 'vitest'
import { evaluateEnergyJourney } from '../../src/dj/energy-journey'
const golden = [
  ['rise', [0.1, 0.2, 0.4, 0.5, 0.8, 0.9], 'follows'],
  ['fall', [0.9, 0.8, 0.5, 0.4, 0.2, 0.1], 'follows'],
  ['arc', [0.2, 0.3, 0.8, 0.9, 0.3, 0.2], 'follows'],
  ['steady', [0.5, 0.51, 0.48, 0.5, 0.52, 0.5], 'follows'],
  ['rise', [0.9, 0.8, 0.5, 0.4, 0.2, 0.1], 'mixed'],
  ['arc', [0.5, 0.5, 0.5, 0.5, 0.5, 0.5], 'mixed'],
] as const
for (const [arc, energies, status] of golden)
  it(`${arc} evaluates ${energies} as ${status}`, () => {
    expect(evaluateEnergyJourney(arc, [...energies]).status).toBe(status)
  })
it('requires enough evidence in every third, not just overall coverage', () => {
  expect(
    evaluateEnergyJourney('rise', [null, null, 0.5, 0.5, 0.8, 0.9]),
  ).toMatchObject({ status: 'limited', bands: null })
  expect(evaluateEnergyJourney('rise', [0.1, 0.5, 0.9]).status).toBe('limited')
  expect(
    evaluateEnergyJourney('rise', [NaN, Infinity, -1, 2, null, null]).known,
  ).toBe(0)
})
it('zero is real energy; missing features never become zero and inputs stay untouched', () => {
  const input = [0, null, 0, 0.5, 0.5, 0.5, 0.9, 0.9, 0.9]
  const before = [...input]
  expect(evaluateEnergyJourney('rise', input)).toMatchObject({
    status: 'follows',
    known: 8,
    bands: [0, 0.5, 0.9],
  })
  expect(input).toEqual(before)
})

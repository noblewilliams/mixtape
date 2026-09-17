import { expect, it } from 'vitest'
import { suggestRoutine } from '../../src/suggestions/patterns'
const now = new Date('2026-09-18T18:00:00Z')
const history = ['2026-08-28', '2026-09-04', '2026-09-11'].map((day) => ({
  createdAt: new Date(`${day}T18:00:00Z`),
  energyArc: 'fall',
}))
it('requires three distinct days, returns only a fixed broad brief and matches the local moment', () => {
  expect(suggestRoutine(history.slice(1), 'UTC', now)).toBeNull()
  expect(
    suggestRoutine([history[0], history[0], history[1]], 'UTC', now),
  ).toBeNull()
  expect(suggestRoutine(history, 'UTC', now)).toMatchObject({
    id: '5-3-fall',
    prompt: 'Make a mix that gradually winds down.',
    reason: 'You have made winding-down mixes on 3 Friday evenings.',
  })
  expect(
    suggestRoutine(history, 'UTC', new Date('2026-09-18T10:00:00Z')),
  ).toBeNull()
})
it('re-evaluates dates and hours in the current IANA zone, including DST', () => {
  const late = ['2026-08-28', '2026-09-04', '2026-09-11'].map((day) => ({
    createdAt: new Date(`${day}T23:30:00Z`),
    energyArc: 'rise',
  }))
  expect(
    suggestRoutine(late, 'Africa/Lagos', new Date('2026-09-18T23:30:00Z')),
  ).toMatchObject({ id: '6-0-rise' })
  const dst = [
    '2026-03-01T14:00Z',
    '2026-03-08T13:00Z',
    '2026-03-15T13:00Z',
  ].map((date) => ({ createdAt: new Date(date), energyArc: 'steady' }))
  expect(
    suggestRoutine(dst, 'America/New_York', new Date('2026-03-22T13:00Z')),
  ).toMatchObject({ id: '0-1-steady' })
})
it('ignores unknown intent, future data and old history', () => {
  expect(
    suggestRoutine(
      history.map((h) => ({ ...h, energyArc: null })),
      'UTC',
      now,
    ),
  ).toBeNull()
  expect(
    suggestRoutine(history, 'UTC', new Date('2027-09-17T18:00Z')),
  ).toBeNull()
  expect(
    suggestRoutine(history, 'UTC', new Date('2026-08-21T18:00Z')),
  ).toBeNull()
})

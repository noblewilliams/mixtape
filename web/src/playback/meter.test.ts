import { expect, it } from 'vitest'
import { ListeningMeter } from './meter'
it('counts observed progress, never seeks, buffering or gaps', () => {
  const events: unknown[] = []
  const meter = new ListeningMeter((e) => events.push(e))
  meter.sample({ index: 0, positionMs: 0, status: 'playing' }, 0)
  meter.sample({ index: 0, positionMs: 1000, status: 'playing' }, 1000)
  meter.sample({ index: 0, positionMs: 120000, status: 'playing' }, 2000)
  meter.sample({ index: 0, positionMs: 121000, status: 'playing' }, 3000)
  meter.sample({ index: 0, positionMs: 122000, status: 'playing' }, 100000)
  meter.sample({ index: 0, positionMs: 122000, status: 'paused' }, 101000)
  meter.finish('listen')
  expect(events).toEqual([{ index: 0, observedMs: 2000, kind: 'listen' }])
})
it('only an explicit next is a skip; unobserved transitions stay neutral', () => {
  const events: unknown[] = []
  const meter = new ListeningMeter((e) => events.push(e))
  meter.sample({ index: 0, positionMs: 0, status: 'playing' }, 0)
  meter.sample({ index: 0, positionMs: 1000, status: 'playing' }, 1000)
  meter.intent = 'skip'
  meter.sample({ index: 1, positionMs: 0, status: 'playing' }, 1500)
  expect(events).toEqual([{ index: 0, observedMs: 1000, kind: 'skip' }])
  meter.sample({ index: 2, positionMs: 0, status: 'playing' }, 2000)
  expect(events[1]).toEqual({ index: 1, observedMs: 0, kind: 'listen' })
})

import { describe, it, expect, beforeEach } from 'vitest'
import { createTestDb } from '../helpers/db'
import { djPauses } from '../../src/db/schema'
import { LlmError, type LlmComplete } from '../../src/dj/llm'
import { TITLE_MODEL } from '../../src/dj/title'
import {
  AUTO_PAUSE_CACHE_MS,
  clearAutoPause,
  pauseOnBilling,
  probeAutoPause,
  readAutoPause,
  resetAutoPauseCache,
  tripAutoPause,
} from '../../src/dj/auto-pause'
import type { Db } from '../../src/db/types'

const broken = new Proxy({}, { get: () => { throw new Error('db down') } }) as unknown as Db

beforeEach(() => resetAutoPauseCache())

describe('auto pause store', () => {
  it('trips, reads and clears through the database', async () => {
    const db = await createTestDb()
    expect(await readAutoPause(db)).toBe(false)
    await tripAutoPause(db)
    await tripAutoPause(db) // idempotent
    expect(await db.select().from(djPauses)).toHaveLength(1)
    resetAutoPauseCache()
    expect(await readAutoPause(db)).toBe(true)
    await clearAutoPause(db)
    expect(await db.select().from(djPauses)).toHaveLength(0)
    expect(await readAutoPause(db)).toBe(false)
  })

  it('caches a read briefly so polling does not hit the database each time', async () => {
    const db = await createTestDb()
    expect(await readAutoPause(db, 1_000)).toBe(false)
    await db.insert(djPauses).values({ id: 'anthropic_billing' })
    expect(await readAutoPause(db, 1_000 + AUTO_PAUSE_CACHE_MS - 1)).toBe(false)
    expect(await readAutoPause(db, 1_000 + AUTO_PAUSE_CACHE_MS)).toBe(true)
  })

  it('reads open when the database fails, and a failed trip does not throw', async () => {
    expect(await readAutoPause(broken)).toBe(false)
    await expect(tripAutoPause(broken)).resolves.toBeUndefined()
  })
})

describe('pauseOnBilling', () => {
  it('trips on a billing failure and rethrows it unchanged', async () => {
    let trips = 0
    const err = new LlmError('HTTP 402', 402, true)
    const wrapped = pauseOnBilling(async (_x: number) => { throw err }, async () => { trips += 1 })
    await expect(wrapped(1)).rejects.toBe(err)
    expect(trips).toBe(1)
  })

  it('leaves other failures and successes alone', async () => {
    let trips = 0
    const onBilling = async () => { trips += 1 }
    await expect(pauseOnBilling(async () => { throw new LlmError('HTTP 529', 529) }, onBilling)()).rejects.toThrow()
    expect(await pauseOnBilling(async (x: number) => x * 2, onBilling)(2)).toBe(4)
    expect(trips).toBe(0)
  })

  it('still rethrows the model error when the trip itself fails', async () => {
    const err = new LlmError('HTTP 402', 402, true)
    const wrapped = pauseOnBilling(async () => { throw err }, async () => { throw new Error('db down') })
    await expect(wrapped()).rejects.toBe(err)
  })
})

describe('probeAutoPause', () => {
  it('does nothing while open', async () => {
    const db = await createTestDb()
    let calls = 0
    const complete: LlmComplete = async () => { calls += 1; return 'ok' }
    expect(await probeAutoPause(db, complete)).toBe('open')
    expect(calls).toBe(0)
  })

  it('clears the pause once the model answers, with one small titling-model call', async () => {
    const db = await createTestDb()
    await tripAutoPause(db)
    const seen: Array<Parameters<LlmComplete>[0]> = []
    const complete: LlmComplete = async (opts) => { seen.push(opts); return 'ok' }
    expect(await probeAutoPause(db, complete)).toBe('cleared')
    expect(await db.select().from(djPauses)).toHaveLength(0)
    expect(seen).toHaveLength(1)
    expect(seen[0]).toMatchObject({ model: TITLE_MODEL, maxRetries: 0 })
    expect(seen[0]!.maxTokens).toBeLessThanOrEqual(16)
  })

  it('stays paused while the model still refuses, for any reason', async () => {
    const db = await createTestDb()
    await tripAutoPause(db)
    for (const err of [new LlmError('HTTP 402', 402, true), new LlmError('HTTP 529', 529)]) {
      expect(await probeAutoPause(db, async () => { throw err })).toBe('still_paused')
    }
    expect(await db.select().from(djPauses)).toHaveLength(1)
  })
})

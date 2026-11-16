import { describe, expect, it } from 'vitest'
import { internalDetail } from '../../src/dj/loop'

describe('internalDetail', () => {
  it('names the error class and the functions on its stack, never the message', () => {
    function buildThing(): never { throw new TypeError('secret listener text "lofi"') }
    let caught: unknown
    try { buildThing() } catch (e) { caught = e }
    const detail = internalDetail(caught)
    expect(detail).toMatch(/^TypeError /)
    expect(detail).toContain('buildThing')
    expect(detail).not.toContain('secret')
    expect(detail).not.toContain('lofi')
  })

  it('keeps a Postgres SQLSTATE code and drops anything else in code', () => {
    const pg = Object.assign(new Error('column "x" does not exist'), { code: '42703' })
    expect(internalDetail(pg)).toContain('42703')
    expect(internalDetail(pg)).not.toContain('column')
    const other = Object.assign(new Error('m'), { code: 'not a sqlstate value' })
    expect(internalDetail(other)).not.toContain('sqlstate')
  })

  it('handles non-errors and stays short', () => {
    expect(internalDetail('boom')).toBe('string')
    expect(internalDetail(undefined)).toBe('undefined')
    const e = new Error('m'); e.stack = 'Error: m\n' + Array.from({ length: 50 }, (_, i) => `    at fn${i}${'x'.repeat(80)} (f.js:1:1)`).join('\n')
    expect(internalDetail(e).length).toBeLessThanOrEqual(200)
  })
})

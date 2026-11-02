import { describe, expect, it } from 'vitest'
import { applyNameEdit, cleanNameInput, normalizeProfileName, PROFILE_NAME_MAX } from './profile-name'

const FLAG = '🇳🇬' // two regional indicators, one character
const FAMILY = '👩‍👩‍👧' // joined with ZWJ

describe('normalizeProfileName (the server rule)', () => {
  it('trims, collapses whitespace and turns line and other whitespace controls into spaces', () => {
    expect(normalizeProfileName('  Ada \n\v\f\u0085  Okafor\t')).toBe('Ada Okafor')
  })

  it('keeps ZWJ and ZWNJ but drops other control and format characters', () => {
    expect(normalizeProfileName(`${FAMILY} می‌خواهم`)).toBe(`${FAMILY} می‌خواهم`)
    expect(normalizeProfileName('A​d‮a\u0007﻿')).toBe('Ada')
  })

  it('caps at 40 code points in whole characters, never cutting a flag', () => {
    expect(PROFILE_NAME_MAX).toBe(40)
    expect(normalizeProfileName(`${'a'.repeat(39)}${FLAG}`)).toBe('a'.repeat(39))
    expect(normalizeProfileName(`${'a'.repeat(38)}${FLAG}`)).toBe(`${'a'.repeat(38)}${FLAG}`)
    expect(normalizeProfileName(`${'a'.repeat(39)}é`)).toBe('a'.repeat(39))
  })
})

describe('cleanNameInput (what the field accepts as you type)', () => {
  it('keeps ZWJ and ZWNJ and does not trim or collapse mid-edit', () => {
    expect(cleanNameInput(`Ada ${FAMILY}‌ `)).toBe(`Ada ${FAMILY}‌ `)
    expect(cleanNameInput('Ada\nOkafor\u0007​')).toBe('Ada Okafor')
  })
})

describe('applyNameEdit (hard stop at 40)', () => {
  const full = 'a'.repeat(40)

  it('refuses typed input at the limit and keeps the caret where it was', () => {
    const typed = 'a'.repeat(20) + 'X' + 'a'.repeat(20)
    expect(applyNameEdit(full, typed, 21)).toEqual({ value: full, caret: 20, cut: true })
  })

  it('trims only the inserted text of a mid-text paste, keeping the text after the caret', () => {
    const prev = 'Ada  Okafor'
    const next = 'Ada ' + 'x'.repeat(40) + ' Okafor'
    const result = applyNameEdit(prev, next, 44)
    expect(result.value).toBe('Ada ' + 'x'.repeat(29) + ' Okafor')
    expect(result.caret).toBe(4 + 29)
    expect(result.cut).toBe(true)
  })

  it('never splits a flag at the cap', () => {
    const prev = 'a'.repeat(39)
    expect(applyNameEdit(prev, prev + FLAG, prev.length + FLAG.length)).toEqual({ value: prev, caret: 39, cut: true })
  })

  it('passes ordinary edits through untouched', () => {
    expect(applyNameEdit('Ada', 'Adda', 2)).toEqual({ value: 'Adda', caret: 2, cut: false })
    expect(applyNameEdit(full, full.slice(1), 0)).toEqual({ value: full.slice(1), caret: 0, cut: false })
  })
})

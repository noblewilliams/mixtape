import { describe, expect, it } from 'vitest'
import stylesheet from './styles.css?raw'

describe('marker typography', () => {
  it('uses the shared descender-safe line height', () => {
    const markerLeading = stylesheet.match(/--marker-leading:\s*([^;]+);/)?.[1]
    expect(markerLeading).toBe('1.2')

    const markerFonts = [...stylesheet.matchAll(/font:\s*([^;]*var\(--marker\))/g)].map((match) => match[1])
    const customLeadings = markerFonts.filter(
      (font) => font.includes('/') && !font.includes('/var(--marker-leading)') && !font.includes('/1.2'),
    )

    expect(customLeadings).toEqual([])
  })
})

describe('secondary typography', () => {
  it('uses the readable secondary scale and never drops below 10px', () => {
    const expectedTokens = {
      '--type-secondary-size': '12px',
      '--type-meta-size': '11px',
      '--type-micro-size': '10px',
      '--type-control-size': '11px',
    }

    for (const [token, size] of Object.entries(expectedTokens)) {
      const declaredSize = stylesheet.match(new RegExp(`${token}:\\s*([^;]+);`))?.[1]
      expect(declaredSize).toBe(size)
    }

    const longhandSizes = [...stylesheet.matchAll(/font-size:\s*([0-9.]+)px/g)].map((match) => Number(match[1]))
    const shorthandSizes = [...stylesheet.matchAll(/font:\s*[^;\n]*?([0-9.]+)px(?:\/|\s)/g)].map((match) => Number(match[1]))

    expect([...longhandSizes, ...shorthandSizes].filter((size) => size < 10)).toEqual([])
  })
})

describe('approved composer treatment', () => {
  it('puts the colorful focus border on the composer shell', () => {
    expect(stylesheet).toMatch(/--stripe-horizontal:\s*linear-gradient\(90deg,/)
    expect(stylesheet).toMatch(/\.composer::after\s*{[^}]*inset:\s*-2px;[^}]*padding:\s*2px;/s)
    expect(stylesheet).toMatch(/\.composer:focus-within::after\s*{[^}]*opacity:\s*1;/s)
    expect(stylesheet).toMatch(/\.composer input\s*{[^}]*border:\s*0;[^}]*outline:\s*0;/s)
  })

  it('keeps the compact send target quiet until hover or keyboard focus', () => {
    expect(stylesheet).toMatch(/\.composer\s*{[^}]*min-height:\s*48px;[^}]*padding:\s*1px 0 1px 10px;/s)
    expect(stylesheet).toMatch(/\.send-button\s*{[^}]*width:\s*44px;[^}]*height:\s*44px;[^}]*margin-right:\s*4px;/s)
    expect(stylesheet).toMatch(/\.send-button-surface\s*{[^}]*width:\s*32px;[^}]*height:\s*32px;[^}]*background:\s*transparent;[^}]*border:\s*0;/s)
    expect(stylesheet).toMatch(/\.send-button:focus-visible\s*{[^}]*outline:\s*0;/s)
    expect(stylesheet).toMatch(/\.send-button:focus-visible \.send-button-surface\s*{[^}]*background:\s*rgba\(84, 68, 81, 0\.09\);/s)
  })
})

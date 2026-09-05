import { describe, expect, it } from 'vitest'
import stylesheet from './your-music.css?raw'

describe('Your music accessibility styles', () => {
  it('keeps interactive controls at least 44px tall', () => {
    expect(stylesheet).toMatch(/\.ym-tabs button\s*{[^}]*min-height:\s*48px;/s)
    expect(stylesheet).toMatch(/\.ym-view \.btn\s*{[^}]*min-height:\s*44px;/s)
    expect(stylesheet).toMatch(/\.ym-toolbar input,\s*\.ym-toolbar select\s*{[^}]*min-height:\s*44px;/s)
  })

  it('provides visible keyboard focus without relying on color alone', () => {
    expect(stylesheet).toMatch(
      /\.ym-view :is\(button, a, input, select\):focus-visible\s*{[^}]*outline:\s*3px solid #5b92b8;[^}]*outline-offset:\s*3px;/s,
    )
  })

  it('ships dark and reduced-transparency field treatments', () => {
    expect(stylesheet).toMatch(
      /@media \(prefers-color-scheme:\s*dark\)[\s\S]*?\.ym-view\s*{[^}]*--ym-field:\s*rgba\(255, 255, 255, 0\.045\);/,
    )
    expect(stylesheet).toMatch(
      /@media \(prefers-reduced-transparency:\s*reduce\)[\s\S]*?\.ym-view\s*{[^}]*--ym-field:\s*#f4f4f1;/,
    )
    expect(stylesheet).toMatch(
      /@media \(prefers-color-scheme:\s*dark\) and \(prefers-reduced-transparency:\s*reduce\)[\s\S]*?\.ym-view\s*{[^}]*--ym-field:\s*#302f34;/,
    )
  })

  it('uses the two-column mobile track layout and never declares sub-10px type', () => {
    expect(stylesheet).toMatch(
      /@media \(max-width:\s*760px\)[\s\S]*?\.ym-track\s*{[^}]*grid-template-columns:\s*18px minmax\(0, 1fr\);/,
    )

    const sizes = [...stylesheet.matchAll(/font-size:\s*([0-9.]+)px/g)].map((match) => Number(match[1]))
    expect(sizes.filter((size) => size < 10)).toEqual([])
  })
})

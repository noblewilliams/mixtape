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

describe('approved artwork mix rail', () => {
  it('keeps the desktop rail wide and turns it into a sheet below 1020px', () => {
    expect(stylesheet).toMatch(/\.app-shell\s*{[^}]*grid-template-columns:\s*238px minmax\(0, 1fr\) 468px;/s)
    expect(stylesheet).toMatch(/@media \(max-width:\s*1020px\)[\s\S]*?\.queue-panel\s*{[^}]*width:\s*min\(468px, calc\(100vw - 32px\)\);/)
  })

  it('keeps the swipe reveal flush and the Undo treatment compact', () => {
    expect(stylesheet).toMatch(/\.track-row\s*{[^}]*--swipe-reveal:\s*0px;[^}]*background:\s*transparent;[^}]*border:\s*0;/s)
    expect(stylesheet).toMatch(/\.track-remove\s*{[^}]*border:\s*0;[^}]*box-shadow:\s*none;/s)
    expect(stylesheet).toMatch(/\.queue-undo-toast\s*{[^}]*min-height:\s*38px;[^}]*padding:\s*4px 9px 4px 12px;/s)
    expect(stylesheet).toMatch(/\.queue-undo-action\s*{[^}]*background:\s*transparent;[^}]*border:\s*0;[^}]*border-radius:\s*0;/s)
    expect(stylesheet).not.toMatch(/\.queue-undo-(?:progress|countdown)/)
  })
})

describe('approved shared content-plane glass', () => {
  it('gives the shell one dynamic paint plane while chrome remains stationary', () => {
    expect(stylesheet).toMatch(/\.app-shell\s*{[^}]*--content-paint:\s*#45596d;[^}]*animation:\s*content-plane-drift 10s ease-in-out infinite;/s)
    expect(stylesheet).toMatch(/@keyframes content-plane-drift\s*{[\s\S]*?26%[\s\S]*?53%[\s\S]*?78%/)
    expect(stylesheet).toMatch(/\.sidebar\s*{[^}]*background:\s*rgba\(248, 247, 246, 0\.62\);[^}]*animation:\s*none;/s)
    expect(stylesheet).toMatch(/\.queue-panel\s*{[^}]*background:\s*rgba\(248, 247, 246, 0\.62\);[^}]*animation:\s*none;/s)
  })

  it('ships purpose-built dark and static accessibility readings', () => {
    expect(stylesheet).toMatch(/@media \(prefers-color-scheme:\s*dark\)[\s\S]*?\.app-shell\s*{[^}]*#151518;/)
    expect(stylesheet).toMatch(/rgba\(var\(--content-paint-rgb\), 0\.34\)/)
    expect(stylesheet).not.toMatch(/color-mix\(in srgb, color-mix\(/)
    expect(stylesheet).toMatch(/@media \(prefers-reduced-motion:\s*reduce\)[\s\S]*?\.app-shell\s*{[^}]*animation:\s*none !important;/)
    expect(stylesheet).toMatch(/@media \(prefers-reduced-transparency:\s*reduce\)[\s\S]*?\.sidebar,[\s\S]*?\.queue-panel[\s\S]*?backdrop-filter:\s*none !important;/)
  })
})

describe('approved Spotify import surfaces', () => {
  it('pins the status chip variants as monospace uppercase pills with a dot, never colour alone', () => {
    expect(stylesheet).toMatch(/\.status-chip\s*{[^}]*border-radius:\s*999px;[^}]*ui-monospace[^}]*text-transform:\s*uppercase;/s)
    expect(stylesheet).toMatch(/\.status-chip\.ok\s*{[^}]*color:\s*#315f42;[^}]*background:\s*#e4f0e7;/s)
    expect(stylesheet).toMatch(/\.status-chip\.wait\s*{[^}]*color:\s*#8a6a3a;[^}]*background:\s*#f4ecdc;/s)
    expect(stylesheet).toMatch(/\.status-chip\.err\s*{[^}]*color:\s*#8a3a49;[^}]*background:\s*#f6e2e6;/s)
    expect(stylesheet).toMatch(/\.status-chip \.dot\s*{[^}]*width:\s*7px;[^}]*background:\s*currentColor;/s)
  })

  it('keeps 44px targets on the buttons and tiles', () => {
    expect(stylesheet).toMatch(/\.btn\s*{[^}]*min-height:\s*44px;/s)
    expect(stylesheet).toMatch(/\.mini\s*{[^}]*min-height:\s*44px;/s)
    expect(stylesheet).toMatch(/\.music-link\s*{[^}]*min-height:\s*52px;/s)
  })

  it('uses the plum raised primary, the translucent secondary, and the pink-bordered quiet destructive', () => {
    expect(stylesheet).toMatch(/\.btn\s*{[^}]*background:\s*rgba\(255, 255, 255, 0\.66\);[^}]*border:\s*1px solid rgba\(73, 64, 72, 0\.2\);/s)
    expect(stylesheet).toMatch(/\.btn\.primary\s*{[^}]*background:\s*#4d404b;[^}]*box-shadow:\s*0 3px 0 #2d272e;/s)
    expect(stylesheet).toMatch(/\.btn\.danger\s*{[^}]*color:\s*#8a3a49;[^}]*border-color:\s*rgba\(201, 104, 127, 0\.45\);/s)
  })

  it('marks attention with the orange hairline and success with the green one', () => {
    expect(stylesheet).toMatch(/\.card\.attention\s*{[^}]*border-color:\s*rgba\(209, 138, 101, 0\.5\);/s)
    expect(stylesheet).toMatch(/\.mini\.done\s*{[^}]*border-color:\s*rgba\(112, 151, 120, 0\.5\);/s)
    expect(stylesheet).toMatch(/\.mini\.done strong::before\s*{[^}]*content:\s*"✓ ";/s)
  })

  it('draws the interview stepper as five flat segments and keeps the dialog on the warm gray', () => {
    expect(stylesheet).toMatch(/\.stepper span\s*{[^}]*width:\s*22px;[^}]*height:\s*4px;/s)
    expect(stylesheet).toMatch(/\.stepper span\.on\s*{[^}]*background:\s*var\(--plum\);/s)
    expect(stylesheet).toMatch(/\.dialog\.interview-dialog,\s*\.dialog\.service-dialog\s*{[^}]*width:\s*min\(520px, calc\(100vw - 32px\)\);/s)
    expect(stylesheet).not.toMatch(/\.(?:interview|service)-dialog[^{]*{[^}]*content-paint/s)
  })

  it('sets the elapsed wait in marker type and the drop zone as a dashed field', () => {
    expect(stylesheet).toMatch(/\.elapsed\s*{[^}]*font:\s*italic 450 30px\/var\(--marker-leading\) var\(--marker\);/s)
    expect(stylesheet).toMatch(/\.drop\s*{[^}]*border:\s*2px dashed rgba\(73, 64, 72, 0\.22\);[^}]*border-radius:\s*16px;/s)
  })

  it('strikes ignored files through and keeps the inventory two-column on desktop', () => {
    expect(stylesheet).toMatch(/\.inventory\s*{[^}]*grid-template-columns:\s*1fr 1fr;/s)
    expect(stylesheet).toMatch(/\.file-list li\.ignored\s*{[^}]*text-decoration:\s*line-through;/s)
  })

  it('hides the paste surface on mobile web and stacks the tiles', () => {
    expect(stylesheet).toMatch(/@media \(max-width:\s*760px\)[\s\S]*?\.mini--desktop,\s*\.paste-box\s*{[^}]*display:\s*none;/)
    expect(stylesheet).toMatch(/@media \(max-width:\s*760px\)[\s\S]*?\.mini-grid,\s*\.mini-grid--pair\s*{[^}]*grid-template-columns:\s*1fr;/)
    expect(stylesheet).toMatch(/@media \(max-width:\s*1020px\)[\s\S]*?\.mini-grid\s*{[^}]*grid-template-columns:\s*1fr 1fr;/)
  })

  it('stops the stripe travel and card transitions under reduced motion', () => {
    expect(stylesheet).toMatch(/@media \(prefers-reduced-motion:\s*reduce\)[\s\S]*?\.progress > span\s*{[^}]*animation:\s*none !important;/)
    expect(stylesheet).toMatch(/@media \(prefers-reduced-motion:\s*reduce\)[\s\S]*?\.card,\s*\.drop,\s*\.switch,\s*\.switch::after\s*{[^}]*transition:\s*none !important;/)
  })

  it('ships the deep-graphite dark reading for cards, chips, and the raised primary', () => {
    expect(stylesheet).toMatch(/@media \(prefers-color-scheme:\s*dark\)[\s\S]*?\.status-chip\.wait\s*{[^}]*color:\s*#e6c98f;[^}]*background:\s*rgba\(209, 138, 101, 0\.14\);/)
    expect(stylesheet).toMatch(/@media \(prefers-color-scheme:\s*dark\)[\s\S]*?\.btn\.primary\s*{[^}]*color:\s*#1b181c;[^}]*background:\s*#e3dbe0;/)
    expect(stylesheet).toMatch(/@media \(prefers-color-scheme:\s*dark\)[\s\S]*?\.music-view\s*{[^}]*background:\s*rgba\(21, 21, 24, 0\.34\);/)
  })

  it('keeps the dialog error line readable on the deep-graphite canvas', () => {
    expect(stylesheet).toMatch(/@media \(prefers-color-scheme:\s*dark\)[\s\S]*?\.dialog-error[^{]*{[^}]*color:\s*#e9a3b3;/)
  })
})

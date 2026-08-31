import { readFile } from 'node:fs/promises'
import { describe, expect, it } from 'vitest'

const webRoot = process.cwd()

describe('web favicon', () => {
  it('uses the tape SVG', async () => {
    const [html, favicon] = await Promise.all([
      readFile(`${webRoot}/index.html`, 'utf8'),
      readFile(`${webRoot}/public/tape.svg`, 'utf8'),
    ])

    expect(html).toContain('<link rel="icon" type="image/svg+xml" href="/tape.svg" />')
    expect(favicon).toContain('<svg')
    expect(favicon).toContain('viewBox="0 0 200 128"')
    expect(favicon).toContain('aria-label="Mixtape cassette"')
  })
})

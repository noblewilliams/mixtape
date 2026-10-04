import { readFile } from 'node:fs/promises'
import { describe, expect, it } from 'vitest'

const webRoot = process.cwd()

describe('web favicon', () => {
  it('uses the tape SVG', async () => {
    const [html, favicon] = await Promise.all([
      readFile(`${webRoot}/index.html`, 'utf8'),
      readFile(`${webRoot}/public/favicon.svg`, 'utf8'),
    ])

    expect(html).toContain('<link rel="icon" type="image/svg+xml" href="/favicon.svg?v=transparent-tape" />')
    expect(favicon).toContain('<svg')
    expect(favicon).not.toContain('<rect width="256" height="256"')
    expect(favicon).toContain('viewBox="0 0 200 128"')
    expect(html).toContain('sizes="32x32" href="/favicon-32.png?v=transparent-tape"')
  })
})

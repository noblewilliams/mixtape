import { readFileSync } from 'node:fs'
import { describe, expect, it } from 'vitest'

describe('Netlify proxy contract', () => {
  it('forwards only auth paths before the SPA fallback', () => {
    const redirects = readFileSync('public/_redirects', 'utf8')
      .split('\n')
      .map((line) => line.trim())
      .filter(Boolean)

    expect(redirects).toEqual([
      '/api/auth/* https://mixtape-api.goalympics.workers.dev/api/auth/:splat 200!',
      '/* /index.html 200',
    ])
  })
})

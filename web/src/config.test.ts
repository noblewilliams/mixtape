import { describe, expect, it } from 'vitest'
import { resolveServiceUrls } from './config'

describe('service URL resolution', () => {
  it('keeps production auth first-party while the application API stays direct', () => {
    expect(
      resolveServiceUrls({
        configuredApiUrl: 'https://mixtape-api.goalympics.workers.dev',
        isProduction: true,
        pageOrigin: 'https://miixtape.netlify.app/',
      }),
    ).toEqual({
      apiUrl: 'https://mixtape-api.goalympics.workers.dev',
      authUrl: 'https://miixtape.netlify.app',
    })
  })

  it('uses the configured backend directly during local development', () => {
    expect(
      resolveServiceUrls({
        configuredApiUrl: 'http://localhost:8787/',
        isProduction: false,
        pageOrigin: 'http://localhost:4176',
      }),
    ).toEqual({
      apiUrl: 'http://localhost:8787',
      authUrl: 'http://localhost:8787',
    })
  })
})

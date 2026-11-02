import { describe, it, expect } from 'vitest'
import { readdirSync, readFileSync, statSync } from 'node:fs'
import { join } from 'node:path'
import { publicAsset } from './public-asset'

describe('publicAsset', () => {
  it('prefixes the app base', () => {
    expect(publicAsset('tape.svg', '/app/')).toBe('/app/tape.svg')
    expect(publicAsset('/ui/status-info.svg', '/app/')).toBe('/app/ui/status-info.svg')
    expect(publicAsset('rack/bird.webp', '/')).toBe('/rack/bird.webp')
  })
})

// Regression guard: production serves the app under /app/, so a root-relative
// public path renders as a broken image there while working in dev.
describe('public asset references', () => {
  it('never hard-code a root-relative public path', () => {
    const publicRoots = readdirSync(join(__dirname, '../../public'))
    const offenders: string[] = []
    const walk = (dir: string) => {
      for (const name of readdirSync(dir)) {
        const path = join(dir, name)
        if (statSync(path).isDirectory()) walk(path)
        else if (/\.(tsx?|css)$/.test(name) && !/\.test\./.test(name)) {
          const text = readFileSync(path, 'utf8')
          for (const root of publicRoots) {
            const escaped = root.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
            if (new RegExp(`["'\`(]/${escaped}`).test(text)) offenders.push(`${path.split('/src/')[1]} → /${root}`)
          }
        }
      }
    }
    walk(join(__dirname, '..'))
    expect(offenders).toEqual([])
  })
})

import { describe, expect, it } from 'vitest'
import { parseArtworkMetadata } from '../../src/artwork/normalize'

const appleUrl = (suffix: string) => `https://is1-ssl.mzstatic.com/image/thumb/${suffix}`

describe('parseArtworkMetadata', () => {
  it('accepts an Apple HTTPS size template without rewriting it', () => {
    const url = appleUrl('Music116/v4/a/b/c/{w}x{h}bb.{f}')

    expect(parseArtworkMetadata({ url, width: 3000, height: 3000, bgColor: 'A1B2C3' })).toEqual({
      url,
      width: 3000,
      height: 3000,
      bgColor: 'a1b2c3',
    })
  })

  it('accepts a concrete Apple HTTPS artwork URL', () => {
    const url = appleUrl('Music116/v4/a/b/c/600x600bb.jpg')

    expect(parseArtworkMetadata({ url, width: 600, height: 600, bgColor: null })).toEqual({
      url,
      width: 600,
      height: 600,
      bgColor: null,
    })
  })

  it.each(['#a1b2c3', ' a1b2c3', 'a1b2c3 ', 'a1b2c', 'a1b2c3d', 'a1b2xz'])(
    'rejects malformed background colour %j',
    (bgColor) => {
      expect(
        parseArtworkMetadata({ url: appleUrl('600x600.jpg'), width: 600, height: 600, bgColor }),
      ).toBeNull()
    },
  )

  it.each([
    { width: 0, height: 10 },
    { width: -1, height: 10 },
    { width: 10, height: 0 },
    { width: 10, height: -1 },
    { width: 1.5, height: 10 },
  ])('rejects non-positive or non-integer dimensions: %j', ({ width, height }) => {
    expect(
      parseArtworkMetadata({ url: appleUrl('600x600.jpg'), width, height, bgColor: 'a1b2c3' }),
    ).toBeNull()
  })

  it('allows dimensions and colour to be absent', () => {
    const url = appleUrl('600x600.jpg')
    expect(parseArtworkMetadata({ url })).toEqual({ url, width: null, height: null, bgColor: null })
  })

  it('accepts a URL at the 2048-character limit and rejects one byte beyond it', () => {
    const prefix = appleUrl('')
    const atLimit = `${prefix}${'a'.repeat(2048 - prefix.length)}`
    const overLimit = `${atLimit}a`

    expect(parseArtworkMetadata({ url: atLimit })?.url).toBe(atLimit)
    expect(parseArtworkMetadata({ url: overLimit })).toBeNull()
  })

  it.each([
    'http://is1-ssl.mzstatic.com/image/cover.jpg',
    'https://example.com/image/cover.jpg',
    'https://mzstatic.com.example.com/image/cover.jpg',
    'https://evil-mzstatic.com/image/cover.jpg',
  ])('rejects non-HTTPS or non-Apple CDN URL %j', (url) => {
    expect(parseArtworkMetadata({ url })).toBeNull()
  })

  it.each([
    appleUrl('{w}x600.jpg'),
    appleUrl('600x{h}.jpg'),
  ])('rejects a URL with only one size placeholder: %j', (url) => {
    expect(parseArtworkMetadata({ url })).toBeNull()
  })
})

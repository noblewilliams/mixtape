import { afterEach, describe, expect, it, vi } from 'vitest'
import { ShareLinkCache, shareLink, sharePendingLink, shareText } from './share-link'

const url = 'https://miixtape.netlify.app/m/4fQ9xK2mZr7TbW1nLpY8sA'

function stub(name: 'share' | 'clipboard', value: unknown) {
  Object.defineProperty(window.navigator, name, { configurable: true, value })
}

afterEach(() => {
  stub('share', undefined)
  stub('clipboard', undefined)
  vi.unstubAllGlobals()
})

class FakeClipboardItem {
  constructor(readonly items: Record<string, Promise<Blob>>) {}
}

describe('shareLink', () => {
  it('words the share text as the contract says', () => {
    expect(shareText('Late drive')).toBe('Listen to my mix “Late drive” on Mixtape')
  })

  it('opens the system share sheet with the link and the text when the browser has one', async () => {
    const share = vi.fn(async () => undefined)
    const writeText = vi.fn(async () => undefined)
    stub('share', share)
    stub('clipboard', { writeText })
    await expect(shareLink(url, 'Late drive')).resolves.toBe('shared')
    expect(share).toHaveBeenCalledWith({ url, text: 'Listen to my mix “Late drive” on Mixtape' })
    expect(writeText).not.toHaveBeenCalled()
  })

  it('treats the listener closing the sheet as nothing happening', async () => {
    stub('share', vi.fn(async () => { throw new DOMException('cancelled', 'AbortError') }))
    const writeText = vi.fn(async () => undefined)
    stub('clipboard', { writeText })
    await expect(shareLink(url, 'Late drive')).resolves.toBe('cancelled')
    expect(writeText).not.toHaveBeenCalled()
  })

  it('copies the link when there is no share sheet', async () => {
    const writeText = vi.fn(async () => undefined)
    stub('clipboard', { writeText })
    await expect(shareLink(url, 'Late drive')).resolves.toBe('copied')
    expect(writeText).toHaveBeenCalledWith(url)
  })

  it('copies the link when the browser refuses the sheet (the tap went stale)', async () => {
    stub('share', vi.fn(async () => { throw new DOMException('no activation', 'NotAllowedError') }))
    const writeText = vi.fn(async () => undefined)
    stub('clipboard', { writeText })
    await expect(shareLink(url, 'Late drive')).resolves.toBe('copied')
  })

  it('fails when neither the sheet nor the clipboard works', async () => {
    await expect(shareLink(url, 'Late drive')).rejects.toThrow()
    stub('clipboard', { writeText: vi.fn(async () => { throw new Error('denied') }) })
    await expect(shareLink(url, 'Late drive')).rejects.toThrow()
  })
})

describe('sharePendingLink', () => {
  it('starts the clipboard write before the link is back, with the link promised', async () => {
    vi.stubGlobal('ClipboardItem', FakeClipboardItem)
    const write = vi.fn(async (_items: FakeClipboardItem[]) => undefined)
    stub('clipboard', { write, writeText: vi.fn() })
    let resolve!: (url: string) => void
    const outcome = sharePendingLink(new Promise((r) => { resolve = r }), 'Late drive')
    expect(write).toHaveBeenCalledTimes(1)
    resolve(url)
    await expect(outcome).resolves.toBe('copied')
    expect(await (await write.mock.calls[0][0][0].items['text/plain']).text()).toBe(url)
  })

  it('falls back to a plain write when the promised write is refused', async () => {
    vi.stubGlobal('ClipboardItem', FakeClipboardItem)
    const writeText = vi.fn(async () => undefined)
    stub('clipboard', { write: vi.fn(async () => { throw new DOMException('no', 'NotAllowedError') }), writeText })
    await expect(sharePendingLink(Promise.resolve(url), 'Late drive')).resolves.toBe('copied')
    expect(writeText).toHaveBeenCalledWith(url)
  })

  it('rejects with the failure to make the link, and writes nothing', async () => {
    vi.stubGlobal('ClipboardItem', FakeClipboardItem)
    const writeText = vi.fn(async () => undefined)
    stub('clipboard', { write: vi.fn(async (items: FakeClipboardItem[]) => { await items[0].items['text/plain'] }), writeText })
    const failure = new Error('name_required')
    await expect(sharePendingLink(Promise.reject(failure), 'Late drive')).rejects.toBe(failure)
    expect(writeText).not.toHaveBeenCalled()
  })

  it('says blocked when the sheet is refused once the link is back, without copying', async () => {
    stub('share', vi.fn(async () => { throw new DOMException('no activation', 'NotAllowedError') }))
    const writeText = vi.fn(async () => undefined)
    stub('clipboard', { writeText })
    await expect(sharePendingLink(Promise.resolve(url), 'Late drive')).resolves.toBe('blocked')
    expect(writeText).not.toHaveBeenCalled()
  })

  it('treats closing the sheet as nothing happening', async () => {
    stub('share', vi.fn(async () => { throw new DOMException('cancelled', 'AbortError') }))
    await expect(sharePendingLink(Promise.resolve(url), 'Late drive')).resolves.toBe('cancelled')
  })

  it('copies with a plain write when there is neither a sheet nor a promised clipboard item', async () => {
    const writeText = vi.fn(async () => undefined)
    stub('clipboard', { writeText })
    await expect(sharePendingLink(Promise.resolve(url), 'Late drive')).resolves.toBe('copied')
    expect(writeText).toHaveBeenCalledWith(url)
  })
})

describe('ShareLinkCache', () => {
  it('keeps a link per mix and queue version, and forgets all of a mix’s links', () => {
    const cache = new ShareLinkCache()
    cache.set('a', 3, 'u3')
    cache.set('a', 4, 'u4')
    cache.set('ab', 3, 'other')
    expect(cache.get('a', 3)).toBe('u3')
    expect(cache.get('a', 5)).toBeUndefined()
    cache.forget('a')
    expect(cache.get('a', 3)).toBeUndefined()
    expect(cache.get('a', 4)).toBeUndefined()
    expect(cache.get('ab', 3)).toBe('other')
  })
})

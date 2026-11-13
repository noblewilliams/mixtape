// Sharing a mix's link from the web app (spec 2026-11-13 shared-mixes,
// Sender): the system share sheet when the browser has one, else the link
// on the clipboard (the caller then shows "Link copied").

// 'blocked': the browser refused the sheet because the tap's activation was
// spent waiting for the link (Safari's NotAllowedError); a fresh tap can share.
export type ShareOutcome = 'shared' | 'copied' | 'cancelled' | 'blocked'

/** The share text, identical on both clients (plan: Shared contract → Copy). */
export function shareText(title: string) {
  return `Listen to my mix “${title}” on Mixtape`
}

/**
 * Closing the sheet is an AbortError and not a failure. Any other refusal
 * (such as Safari's NotAllowedError once the tap's activation has passed)
 * falls back to copying. Throws only when neither works.
 */
export async function shareLink(url: string, title: string): Promise<ShareOutcome> {
  if (typeof navigator.share === 'function') {
    try {
      await navigator.share({ url, text: shareText(title) })
      return 'shared'
    } catch (error) {
      if (isAbort(error)) return 'cancelled'
    }
  }
  if (!navigator.clipboard?.writeText) throw new Error('No way to share this link')
  await navigator.clipboard.writeText(url)
  return 'copied'
}

const isAbort = (error: unknown) => error instanceof DOMException && error.name === 'AbortError'
const isNotAllowed = (error: unknown) => error instanceof DOMException && error.name === 'NotAllowedError'

/** The browser takes a ClipboardItem whose data is a promise (Safari, current Chrome). */
function canWritePromisedText() {
  return typeof ClipboardItem === 'function' && typeof navigator.clipboard?.write === 'function'
}

/**
 * Shares a link that is still being made. Call it synchronously from the tap:
 * Safari spends the tap's activation on the first await, after which the share
 * sheet and the clipboard refuse.
 *
 * With no share sheet, the clipboard write starts inside the tap with the link
 * promised, where the browser allows it. With a sheet, the sheet opens once the
 * link is back; if the browser refuses it then, the outcome is 'blocked' and a
 * fresh tap (shareLink) can share. A failure to make the link rejects with that
 * failure, which the caller reads from `pending` itself.
 */
export function sharePendingLink(pending: Promise<string>, title: string): Promise<ShareOutcome> {
  if (typeof navigator.share !== 'function' && canWritePromisedText()) {
    const blob = pending.then((url) => new Blob([url], { type: 'text/plain' }))
    blob.catch(() => undefined)
    const written = navigator.clipboard.write([new ClipboardItem({ 'text/plain': blob })])
    written.catch(() => undefined)
    return (async (): Promise<ShareOutcome> => {
      const url = await pending
      try {
        await written
        return 'copied'
      } catch {
        // The promised write was refused: try a plain one.
      }
      if (!navigator.clipboard?.writeText) throw new Error('No way to share this link')
      await navigator.clipboard.writeText(url)
      return 'copied'
    })()
  }
  return pending.then(async (url): Promise<ShareOutcome> => {
    if (typeof navigator.share === 'function') {
      try {
        await navigator.share({ url, text: shareText(title) })
        return 'shared'
      } catch (error) {
        if (isAbort(error)) return 'cancelled'
        if (isNotAllowed(error)) return 'blocked'
      }
    }
    if (!navigator.clipboard?.writeText) throw new Error('No way to share this link')
    await navigator.clipboard.writeText(url)
    return 'copied'
  })
}

/**
 * The links this page has made, per mix and queue version: the server
 * snapshots a share per version, so a changed queue needs a new link. Forget a
 * mix's links when a read says it is no longer shared (stopped elsewhere) or
 * after a rename.
 */
export class ShareLinkCache {
  private links = new Map<string, string>()
  get(sessionId: string, version: number) {
    return this.links.get(`${sessionId}:${version}`)
  }
  set(sessionId: string, version: number, url: string) {
    this.links.set(`${sessionId}:${version}`, url)
  }
  forget(sessionId: string) {
    for (const key of [...this.links.keys()]) if (key.startsWith(`${sessionId}:`)) this.links.delete(key)
  }
}

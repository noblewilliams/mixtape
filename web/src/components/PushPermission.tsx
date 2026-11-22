import { useCallback, useEffect, useId, useRef, useState } from 'react'
import { ControlModal } from './ControlModal'
import { Cassette } from './Cassette'
import { publicAsset } from '../lib/public-asset'
import { useMediaQuery } from '../lib/use-media-query'
import {
  currentPushSubscription,
  disablePush,
  enablePush,
  markPushAsked,
  pushAskState,
  pushPermission,
  pushSupported,
  registerPush,
  type PushApi,
  type ReadPushKey,
} from '../lib/web-push'
import './web-controls.css'
import './push-permission.css'

// Copy is locked by docs/mockups/approved/2026-11-21-push-permission-modal.md (web column).
export const PUSH_TITLE = 'Want a ping when it’s ready?'
export const PUSH_BODY = 'Mixes take up to a minute. Close the tab, get on with your day, and we’ll tell you the moment yours is ready.'
export const PUSH_TURN_ON = 'Turn on notifications'
export const PUSH_NOT_NOW = 'Not now'
export const PUSH_ROW_TITLE = 'Mix ready notifications'
export const PUSH_ROW_LINE = 'A ping when a mix lands'
export const PUSH_ROW_BLOCKED = 'Blocked in your browser settings'
/** On Making your mix after Allow. */
export const PUSH_PINGING = 'We’ll ping you when it’s ready.'

/** I1 at web size: the cassette, tilted, with a small "Your mix is ready" rising out of it. Decorative. */
function PushArt() {
  const still = useMediaQuery('(prefers-reduced-motion: reduce)')
  return (
    <div className="push-art" aria-hidden="true" data-testid="push-art">
      <div className="push-toast">
        <img className="push-toast-icon" src={publicAsset('icons/icon-192.png')} alt="" />
        <span><b>Your mix is ready</b><small>Sunday kitchen soul</small></span>
        <time>now</time>
      </div>
      <span className="push-tape"><Cassette loading={!still} labelled={false} /></span>
    </div>
  )
}

/** The pop-up itself: a centred dialog over a blurred page. Tap outside and Escape are Not now. */
export function PushPermission({ onTurnOn, onNotNow }: { onTurnOn: () => void; onNotNow: () => void }) {
  const bodyId = useId()
  return (
    <ControlModal title={PUSH_TITLE} className="push-permission" overlay="blur" describedBy={bodyId} before={<PushArt />} onClose={onNotNow}>
      <p id={bodyId}>{PUSH_BODY}</p>
      <div className="push-actions">
        <button type="button" className="wc-text" onClick={onNotNow} data-autofocus>{PUSH_NOT_NOW}</button>
        <button type="button" className="wc-text push-turn-on" onClick={onTurnOn}>{PUSH_TURN_ON}</button>
      </div>
    </ControlModal>
  )
}

/** Any dialog already up (the AI consent, a confirmation, a sheet): the pop-up never stacks on one. */
function anotherModalOpen(): boolean {
  return document.querySelector('[aria-modal="true"]') !== null
}

/** One silent registration per api (that is, per sign-in) and page load, once permission is granted. */
const silentlyRegistered = new WeakSet<object>()

type OfferProps = {
  api: PushApi
  readKey: ReadPushKey
  /** The moment is right (Making your mix, the working state, Home). */
  when: boolean
  /** How long `when` must hold first (about 3 s into a prompt; a beat on Home). */
  delayMs?: number
  /** Something of the caller's own is up (the AI consent, a sheet): wait for it to close. */
  blocked?: boolean
  /** The browser said yes (and the subscription went up, or was tried). */
  onEnabled?: () => void
}

/**
 * Offers the pop-up once per browser, only where push can work and the
 * browser has not decided yet, and the server publishes a key. Already
 * granted: registers silently, no pop-up. Denied: nothing, ever.
 */
export function PushOffer({ api, readKey, when, delayMs = 3000, blocked = false, onEnabled }: OfferProps) {
  const [key, setKey] = useState<string | null>(null)
  const [open, setOpen] = useState(false)
  const apiRef = useRef(api)
  apiRef.current = api
  const readKeyRef = useRef(readKey)
  readKeyRef.current = readKey
  const enabled = useRef(onEnabled)
  enabled.current = onEnabled

  useEffect(() => {
    if (!pushSupported() || pushPermission() === 'denied') return
    let live = true
    let reading: Promise<string | null | undefined>
    try { reading = readKeyRef.current() } catch { return }
    reading.then((value) => { if (live && typeof value === 'string' && value) setKey(value) }, () => undefined)
    return () => { live = false }
  }, [])

  useEffect(() => {
    if (!key || pushPermission() !== 'granted' || silentlyRegistered.has(apiRef.current)) return
    silentlyRegistered.add(apiRef.current)
    void registerPush(apiRef.current, key)
  }, [key])

  const eligible = key !== null && pushPermission() === 'default' && pushAskState() === 'unasked'
  useEffect(() => {
    if (!eligible || !when || blocked || open) return
    let timer: ReturnType<typeof setTimeout>
    const attempt = () => {
      if (anotherModalOpen()) {
        timer = setTimeout(attempt, 1000)
        return
      }
      if (pushPermission() !== 'default' || pushAskState() !== 'unasked') return
      // Set the moment it appears; if it cannot be written, "once" cannot be kept, so it never shows.
      if (!markPushAsked()) return
      setOpen(true)
    }
    timer = setTimeout(attempt, delayMs)
    return () => clearTimeout(timer)
  }, [eligible, when, blocked, open, delayMs])

  const notNow = useCallback(() => setOpen(false), [])
  const turnOn = useCallback(() => {
    setOpen(false)
    if (!key) return
    // Called inside the click: requestPermission runs before anything is awaited.
    void enablePush(apiRef.current, key).then((permission) => {
      if (permission === 'granted') {
        silentlyRegistered.add(apiRef.current)
        enabled.current?.()
      }
    })
  }, [key])

  // Held, not dropped, while the caller's own dialog is up: it comes back once that closes.
  if (!open || blocked) return null
  return <PushPermission onTurnOn={turnOn} onNotNow={notNow} />
}

type RowState =
  | { kind: 'hidden' }
  | { kind: 'blocked' }
  | { kind: 'switch'; on: boolean; key: string }

/** Settings → This device: on/off for this browser; hidden where push cannot work or the server has it off. */
export function PushNotificationsRow({ api, readKey }: { api: PushApi; readKey: ReadPushKey }) {
  const [state, setState] = useState<RowState>({ kind: 'hidden' })
  const [busy, setBusy] = useState(false)
  const live = useRef(true)
  const apiRef = useRef(api)
  apiRef.current = api

  const refresh = useCallback(async (key: string) => {
    const permission = pushPermission()
    if (permission === 'unsupported') return setState({ kind: 'hidden' })
    if (permission === 'denied') return setState({ kind: 'blocked' })
    const subscription = permission === 'granted' ? await currentPushSubscription() : null
    if (live.current) setState({ kind: 'switch', on: subscription !== null, key })
  }, [])

  useEffect(() => {
    live.current = true
    if (!pushSupported()) return
    let reading: Promise<string | null | undefined>
    try { reading = readKey() } catch { return }
    reading.then((value) => {
      if (!live.current) return
      if (typeof value === 'string' && value) void refresh(value)
      else if (pushPermission() === 'denied') setState({ kind: 'blocked' })
    }, () => undefined)
    return () => { live.current = false }
  }, [])

  if (state.kind === 'hidden') return null
  if (state.kind === 'blocked') {
    return (
      <div className="setting-row" data-testid="push-row">
        <span>
          <strong>{PUSH_ROW_TITLE}</strong>
          <small>{PUSH_ROW_BLOCKED}</small>
        </span>
      </div>
    )
  }

  async function toggle(on: boolean, key: string) {
    setBusy(true)
    try {
      if (on) {
        // The pop-up never needs to ask after this.
        markPushAsked()
        await enablePush(apiRef.current, key)
      } else {
        await disablePush(apiRef.current)
      }
      await refresh(key)
    } finally {
      if (live.current) setBusy(false)
    }
  }

  return (
    <label className="setting-row" data-testid="push-row">
      <span>
        <strong>{PUSH_ROW_TITLE}</strong>
        <small>{PUSH_ROW_LINE}</small>
      </span>
      <input type="checkbox" checked={state.on} disabled={busy} onChange={(event) => void toggle(event.target.checked, state.key)} />
    </label>
  )
}

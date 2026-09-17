import { useEffect, useRef, useState, type CSSProperties } from 'react'
import type { DjSession } from '../domain'

export function InlineMixName({
  title,
  onRename,
}: {
  title: string
  onRename: (title: string) => Promise<void>
}) {
  const [editing, setEditing] = useState(false)
  const [draft, setDraft] = useState(title)
  const [error, setError] = useState('')
  const [busy, setBusy] = useState(false)
  const saving = useRef(false)
  const cancelling = useRef(false)
  const mounted = useRef(true)
  const input = useRef<HTMLInputElement>(null)
  useEffect(() => {
    mounted.current = true
    return () => {
      mounted.current = false
    }
  }, [])
  useEffect(() => {
    if (editing) {
      input.current?.focus()
      input.current?.select()
    }
  }, [editing])
  async function save() {
    if (saving.current || cancelling.current) return
    if (!draft.trim()) {
      setError('Give your mix a name.')
      return
    }
    if (draft.trim() === title) {
      setEditing(false)
      return
    }
    saving.current = true
    setBusy(true)
    setError('')
    try {
      await onRename(draft.trim())
      if (mounted.current) setEditing(false)
    } catch {
      if (mounted.current) setError('Couldn’t save the name. Try again.')
    } finally {
      saving.current = false
      if (mounted.current) setBusy(false)
    }
  }
  return editing ? (
    <div className="wc-inline-edit">
      <input
        ref={input}
        aria-label="Mix name"
        aria-invalid={Boolean(error)}
        value={draft}
        maxLength={60}
        disabled={busy}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={() => void save()}
        onKeyDown={(e) => {
          if (e.key === 'Enter') {
            e.preventDefault()
            void save()
          }
          if (e.key === 'Escape') {
            cancelling.current = true
            setEditing(false)
          }
        }}
      />
      {busy ? (
        <small role="status">Saving…</small>
      ) : error ? (
        <>
          <small role="alert">{error}</small>
          <button className="wc-text" onMouseDown={(e) => e.preventDefault()} onClick={() => void save()}>
            Retry
          </button>
        </>
      ) : (
        <small>Enter to save · Escape to cancel</small>
      )}
    </div>
  ) : (
    <button
      className="wc-name"
      aria-label={`Rename ${title}`}
      onClick={() => {
        cancelling.current = false
        setDraft(title)
        setError('')
        setEditing(true)
      }}
    >
      {title}
    </button>
  )
}

export function SessionRow({
  session,
  onOpen,
  onRename,
  onArchive,
  onRestore,
}: {
  session: DjSession
  onOpen: () => void
  onRename: (title: string) => Promise<void>
  onArchive: () => Promise<void>
  onRestore?: () => Promise<void>
}) {
  const [menu, setMenu] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [reveal, setReveal] = useState(0)
  const row = useRef<HTMLDivElement>(null)
  const menuElement = useRef<HTMLDivElement>(null)
  const menuButton = useRef<HTMLButtonElement>(null)
  const gesture = useRef<{ x: number; y: number; width: number; horizontal: boolean; reveal: number } | null>(
    null,
  )
  const suppress = useRef(false)
  const running = useRef(false)
  const wheel = useRef<ReturnType<typeof setTimeout> | null>(null)
  useEffect(() => {
    if (!menu) return
    const outside = (e: PointerEvent) => {
      if (!menuElement.current?.contains(e.target as Node) && !menuButton.current?.contains(e.target as Node))
        setMenu(false)
    }
    const escape = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        setMenu(false)
        menuButton.current?.focus()
      }
    }
    document.addEventListener('pointerdown', outside)
    document.addEventListener('keydown', escape)
    return () => {
      document.removeEventListener('pointerdown', outside)
      document.removeEventListener('keydown', escape)
    }
  }, [menu])
  useEffect(
    () => () => {
      if (wheel.current) clearTimeout(wheel.current)
    },
    [],
  )
  async function act(action: () => Promise<void>) {
    if (running.current) return
    running.current = true
    setBusy(true)
    setError('')
    setMenu(false)
    setReveal(0)
    try {
      await action()
    } catch {
      setError('Couldn’t update this mix. Try again.')
    } finally {
      running.current = false
      setBusy(false)
    }
  }
  const finish = (amount: number, width: number) => {
    if (amount >= width * 0.65) void act(onArchive)
    else setReveal(amount >= 18 ? 44 : 0)
  }
  return (
    <div ref={row} className={`wc-session-row ${menu ? 'has-menu' : ''}`}>
      {session.status === 'active' && reveal > 0 && (
        <div className="wc-archive-reveal">
          <button
            className="wc-text"
            aria-label="Archive"
            disabled={busy}
            onClick={() => void act(onArchive)}
          >
            ←
          </button>
        </div>
      )}
      <div
        className="wc-session-surface"
        style={{ '--wc-reveal': `${reveal}px` } as CSSProperties}
        onKeyDown={(event) => {
          if ((event.target as HTMLElement).closest('input')) return
          if (event.key === 'Delete' && session.status === 'active') {
            event.preventDefault()
            setReveal(44)
          }
          if (event.key === 'Escape') setReveal(0)
        }}
        onClickCapture={(e) => {
          if (suppress.current) {
            e.preventDefault()
            e.stopPropagation()
            suppress.current = false
          }
        }}
        onPointerDown={(e) => {
          if (
            busy ||
            session.status !== 'active' ||
            e.button !== 0 ||
            (e.target as HTMLElement).closest('input')
          )
            return
          suppress.current = false
          gesture.current = {
            x: e.clientX,
            y: e.clientY,
            width: e.currentTarget.getBoundingClientRect().width,
            horizontal: false,
            reveal: 0,
          }
        }}
        onPointerMove={(e) => {
          const g = gesture.current
          if (!g) return
          const dx = g.x - e.clientX
          if (!g.horizontal) {
            if (Math.abs(dx) < 6) return
            if (Math.abs(g.y - e.clientY) > Math.abs(dx)) {
              gesture.current = null
              return
            }
            g.horizontal = true
            e.currentTarget.setPointerCapture?.(e.pointerId)
          }
          e.preventDefault()
          g.reveal = Math.max(0, Math.min(g.width, dx))
          setReveal(g.reveal)
        }}
        onPointerUp={() => {
          const g = gesture.current
          gesture.current = null
          if (!g?.horizontal) return
          suppress.current = true
          finish(g.reveal, g.width)
        }}
        onPointerCancel={() => {
          gesture.current = null
          setReveal(0)
        }}
        onWheel={(e) => {
          if (
            busy ||
            session.status !== 'active' ||
            Math.abs(e.deltaX) <= Math.abs(e.deltaY) ||
            Math.abs(e.deltaX) < 2
          )
            return
          e.preventDefault()
          const width = e.currentTarget.getBoundingClientRect().width
          const amount = Math.max(0, Math.min(width, reveal + e.deltaX))
          setReveal(amount)
          if (wheel.current) clearTimeout(wheel.current)
          wheel.current = setTimeout(() => finish(amount, width), 120)
        }}
      >
        <div className="wc-session-copy">
          <InlineMixName title={session.title} onRename={onRename} />
          <small>
            {session.trackCount} songs · {session.ageLabel}
          </small>
        </div>
        <button className="wc-text" onClick={onOpen} aria-label={`Open ${session.title}`}>
          Open
        </button>
        {session.status === 'archived' ? (
          <button className="wc-text" disabled={busy} onClick={() => onRestore && void act(onRestore)}>
            Restore
          </button>
        ) : (
          <button
            ref={menuButton}
            className="wc-text"
            disabled={busy}
            aria-label="Mix actions"
            aria-expanded={menu}
            onClick={() => setMenu((value) => !value)}
          >
            •••
          </button>
        )}
      </div>
      {menu && (
        <div ref={menuElement} className="wc-popover wc-session-menu" role="group" aria-label="Mix actions">
          <button className="wc-text" onClick={() => void act(onArchive)}>
            Archive
          </button>
        </div>
      )}
      {error && <p role="alert">{error}</p>}
    </div>
  )
}

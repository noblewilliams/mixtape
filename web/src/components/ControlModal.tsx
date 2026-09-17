import { useEffect, useId, useRef, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

export function ControlModal({
  title,
  children,
  onClose,
  alert = false,
}: {
  title: string
  children: ReactNode
  onClose: () => void
  alert?: boolean
}) {
  const id = useId()
  const ref = useRef<HTMLElement>(null)
  const close = useRef(onClose)
  close.current = onClose
  useEffect(() => {
    const previous = document.activeElement as HTMLElement | null
    const parent = ref.current!.parentElement!
    const siblings = [...document.body.children].filter((node) => node !== parent) as HTMLElement[]
    const prior = siblings.map((node) => node.inert)
    siblings.forEach((node) => {
      node.inert = true
    })
    const focusable = () => [
      ...ref.current!.querySelectorAll<HTMLElement>(
        'button:not(:disabled),input:not(:disabled),textarea:not(:disabled),[tabindex="0"]',
      ),
    ]
    ;(focusable()[0] ?? ref.current)?.focus()
    const keydown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault()
        close.current()
      }
      if (event.key === 'Tab') {
        const nodes = focusable()
        if (!nodes.length) {
          event.preventDefault()
          return
        }
        if (event.shiftKey && document.activeElement === nodes[0]) {
          event.preventDefault()
          nodes.at(-1)?.focus()
        } else if (!event.shiftKey && document.activeElement === nodes.at(-1)) {
          event.preventDefault()
          nodes[0].focus()
        }
      }
    }
    document.addEventListener('keydown', keydown)
    return () => {
      document.removeEventListener('keydown', keydown)
      siblings.forEach((node, index) => {
        node.inert = prior[index]
      })
      if (previous?.isConnected) previous.focus()
    }
  }, [])
  return createPortal(
    <div
      className="wc-overlay"
      onMouseDown={(event) => {
        if (event.target === event.currentTarget) onClose()
      }}
    >
      <section
        ref={ref}
        tabIndex={-1}
        className="wc-modal"
        role={alert ? 'alertdialog' : 'dialog'}
        aria-modal="true"
        aria-labelledby={id}
      >
        <h2 id={id}>{title}</h2>
        {children}
      </section>
    </div>,
    document.body,
  )
}

import { useId, type MouseEvent } from 'react'
import { flushSync } from 'react-dom'
import { useTheme, type Theme } from '../theme'
import '../theme.css'

type ViewTransitionDocument = Document & { startViewTransition?: (update: () => void) => { ready: Promise<void> } }

function reveal(setTheme: (theme: Theme) => void, origin: HTMLElement) {
  const doc = document as ViewTransitionDocument
  // Read the theme when the change applies, so a second press before the first lands still flips it.
  const apply = () => setTheme(document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark')
  if (typeof doc.startViewTransition !== 'function' || window.matchMedia?.('(prefers-reduced-motion: reduce)').matches) return apply()
  const rect = origin.getBoundingClientRect()
  const x = rect.left + rect.width / 2, y = rect.top + rect.height / 2
  const end = Math.hypot(Math.max(x, window.innerWidth - x), Math.max(y, window.innerHeight - y))
  doc.startViewTransition(() => flushSync(apply)).ready
    .then(() => document.documentElement.animate(
      { clipPath: [`circle(0px at ${x}px ${y}px)`, `circle(${end}px at ${x}px ${y}px)`] },
      { duration: 620, easing: 'cubic-bezier(.45,0,.2,1)', pseudoElement: '::view-transition-new(root)' },
    ))
    // A hidden tab skips the transition; the theme still applies.
    .catch(() => {})
}

export function ThemeToggle() {
  const [theme, setTheme] = useTheme()
  const maskId = useId()
  const dark = theme === 'dark'
  return (
    <button
      type="button"
      className="theme-toggle"
      role="switch"
      aria-label="Dark mode"
      aria-checked={dark}
      title={`Switch to ${dark ? 'light' : 'dark'} mode`}
      onClick={(event: MouseEvent<HTMLButtonElement>) => reveal(setTheme, event.currentTarget)}
    >
      <svg viewBox="0 0 32 32" aria-hidden="true" focusable="false">
        <defs>
          <mask id={maskId} maskUnits="userSpaceOnUse" x="0" y="0" width="32" height="32">
            <rect width="32" height="32" fill="#fff" />
            <circle className="theme-hole" cx="16" cy="16" r="2.4" fill="#000" />
            <circle className="theme-cut" cx="16" cy="16" r="7.6" fill="#000" />
          </mask>
        </defs>
        <g className="theme-rays">
          {Array.from({ length: 8 }, (_, index) => <rect key={index} x="14.8" y="2.4" width="2.4" height="4.6" rx="1.2" transform={`rotate(${index * 45} 16 16)`} style={{ transformOrigin: '0 0', transformBox: 'view-box' }} />)}
        </g>
        <g mask={`url(#${maskId})`}><circle className="theme-body" cx="16" cy="16" r="8.6" /></g>
        <circle className="theme-star" cx="24.6" cy="7.2" r="1.15" />
        <circle className="theme-star" cx="27.2" cy="13.4" r=".75" />
      </svg>
    </button>
  )
}

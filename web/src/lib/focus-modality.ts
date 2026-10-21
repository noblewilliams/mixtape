/**
 * Focus rings only for keyboard navigation (founder, 2026-10-21). The root
 * carries `data-focus="pointer" | "keyboard"`; styles.css hides
 * `:focus-visible` rings while it is `pointer`. Pointer is the starting value.
 */
export type FocusModality = 'pointer' | 'keyboard'

const NAVIGATION_KEYS = new Set(['Tab', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Enter', ' ', 'Spacebar'])

let installed: (() => void) | null = null

function set(modality: FocusModality) {
  const root = document.documentElement
  if (root.dataset.focus !== modality) root.dataset.focus = modality
}

/** Install once (main.tsx); returns the teardown. A second install is a no-op. */
export function installFocusModality(): () => void {
  if (installed) return () => {}
  const onPointer = () => set('pointer')
  const onKey = (event: KeyboardEvent) => {
    if (NAVIGATION_KEYS.has(event.key)) set('keyboard')
  }
  set('pointer')
  // Capture, so a component stopping propagation cannot hide the change.
  window.addEventListener('pointerdown', onPointer, true)
  // Safari has delivered mousedown without pointerdown on some controls.
  window.addEventListener('mousedown', onPointer, true)
  window.addEventListener('keydown', onKey, true)
  const teardown = () => {
    window.removeEventListener('pointerdown', onPointer, true)
    window.removeEventListener('mousedown', onPointer, true)
    window.removeEventListener('keydown', onKey, true)
    if (installed === teardown) installed = null
  }
  installed = teardown
  return teardown
}

/** Remove the listeners installed by installFocusModality (tests). */
export function teardownFocusModality(): void {
  installed?.()
}

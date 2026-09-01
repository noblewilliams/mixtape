# Web artwork mix rail Undo toast refinement

- **Approved:** 2026-09-01
- **Board:** `docs/mockups/2026-08-31-web-artwork-mix-rail-final.html`
- **Winning direction:** a compact, low-padding success toast whose Undo action reads as part of the message rather than as a separate contained button.
- **Supersedes:** only the Undo-toast presentation and visible-countdown clauses in `docs/mockups/approved/2026-08-31-web-artwork-mix-rail.md`. All other appearance, interaction, responsive, accessibility, and implementation decisions in that approval remain locked.

## Locked appearance

- The rail toast has a 38px minimum height with 4px vertical padding, 12px leading padding, and 9px trailing padding.
- Undo is a transparent, borderless, radius-free icon-and-text action with a 13px undo SVG and a 28px minimum interaction height.
- There is no visible Undo container, countdown, progress bar, or other time indicator.
- The supporting compact state preview uses the same visual treatment, with 5px vertical padding and no progress indicator.

## Locked behavior and accessibility

- Removal and reorder remain reversible for exactly three seconds. Removing the visible countdown does not alter the timer or single-level Undo behavior.
- The status message remains announced through the live region. The Undo action remains keyboard reachable and retains visible text alongside its decorative SVG.
- Expiry is quiet: the toast disappears after three seconds without a visual countdown.
- Reduced-motion behavior remains unchanged.

## Rejected refinements

- A separately filled, bordered, or rounded Undo button: it made the action look detached from the toast message.
- A three-second progress bar or numeric countdown: it added visual noise to a brief recovery action.
- The earlier 46px toast with 8–10px vertical padding: it felt too tall for the rail's compact density.

## Implementation boundary

- Expected web owners remain `web/src/components/QueuePanel.tsx`, `web/src/components/Icons.tsx`, and `web/src/styles.css`.
- Preserve a comfortably clickable Undo target when translating the visually compact 28px mockup control into production semantics; invisible hit-area expansion may be used without changing the approved appearance.
- No behavior or backend contract decision is changed by this refinement.

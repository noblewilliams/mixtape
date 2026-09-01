# Web shared content-plane liquid glass approval

- **Approved:** 2026-09-01
- **Board:** `docs/mockups/2026-09-01-web-neutral-liquid-glass-directions.html`
- **Winning direction:** C, one subtly painted content plane moving beneath translucent navigation and queue glass.
- **Supersedes:** the colorful ambient-room direction in `docs/mockups/2026-08-31-web-liquid-glass-system-directions.html`; the earlier proposal that animated paint independently inside the side rails; and the light-only theme boundaries in the composer and artwork-rail approvals.

## Locked appearance and layer ownership

- Chat, Home, and other primary application views own one continuous, softly painted background plane.
- Desktop navigation and queue panes sit above that plane with translucent neutral fills and blur. They reveal a quieter trace of the moving paint but never own separate gradients or animations.
- The center content shows the paint more clearly than the side panes. The effect remains subtle and never becomes a colorful ambient room.
- The focused composer keeps its approved neutral interior, five-color border, compact straight-up send arrow, and subtle button interaction background.
- Home uses Mixtape's restrained slate house paint. Opening a mix replaces it with that mix's stable cassette paint; renaming or refining a mix does not change its paint identity.
- Authentication, account dialogs, and other temporary foreground surfaces remain neutral and do not borrow mix paint.

## Locked motion

- The paint follows a 10-second, multi-directional four-point path rather than a single horizontal sweep.
- Motion changes position only. Hue does not cycle, blur does not animate, and navigation, queue, top chrome, composers, and controls remain visually stationary.
- Each primary view owns at most one animated background plane.
- Reduced-motion mode removes the animation and preserves a balanced static gradient frame.

## Dark mode

- Dark mode is purpose-built rather than an inversion: the canvas is deep graphite `#151518`, with the same paint identity expressed as a cool low-light reflection.
- Desktop side panes become smoky translucent glass above the moving content plane.
- Mobile uses the same content-plane hierarchy, with a translucent non-animated top bar and neutral composer above it.
- Reduced-transparency mode replaces glass with opaque warm gray in light mode and opaque graphite in dark mode.
- The shipped theme follows the system color preference unless a later product decision adds a manual override.

## Responsive and accessibility behavior

- Desktop chat uses both translucent left navigation and right queue panes. Desktop Home uses the translucent left navigation pane.
- Mobile Home and chat keep the moving content plane but omit desktop sidebars; the top bar is translucent and does not animate independently.
- Mobile composer input text remains 16px, while the approved control targets and accessible names remain unchanged.
- Color and motion are decorative. Content hierarchy, labels, focus treatment, and status text remain complete when animation or transparency is reduced.

## Rejected directions

- A, colorful ambient room: too saturated and competed with content and artwork.
- B, fully neutral chrome: clear and restrained, but lacked the desired sense of light and material movement.
- Separate gradients in left navigation, right queue, or mobile top chrome: made the shell feel like several unrelated animated panels.
- A slow horizontal sweep: too easy to miss and felt mechanical rather than liquid.

## Implementation boundary

- Expected web owners: `web/src/App.tsx`, `web/src/components/Conversation.tsx`, `web/src/components/QueuePanel.tsx`, `web/src/components/AuthGate.tsx`, `web/src/components/Overlays.tsx`, and `web/src/styles.css`.
- Add focused style and component regression coverage under `web/src/` for layer ownership, light/dark tokens, reduced motion, reduced transparency, and mobile behavior.
- The actual mix-paint value should come from one stable session-level value when available. Until that data contract exists, the approved slate paint is the visual fallback; a transient prompt or queue change must not cause a visible color jump.

# Web artwork mix rail approval

- **Approved:** 2026-08-31
- **Board:** `docs/mockups/2026-08-31-web-artwork-mix-rail-final.html`
- **Winning direction:** a persistent, artwork-led right rail wide enough to arrange the mix directly beside the DJ conversation.
- **Supersedes:** the floating-widget directions in `docs/mockups/2026-08-31-web-floating-mix-widget-directions.html`, the alternate workspace/shelf directions in `docs/mockups/2026-08-31-web-artwork-reorder-mix-directions.html`, and the current narrow numbered queue with inactive per-track menus.

## Locked appearance

- Desktop uses a persistent 468px right rail. It contains the complete track arrangement and the sticky Play now/Create playlist actions; there is no separate Talk/Mix workspace.
- Rows use album artwork, title, artist, duration, and one reserved reason line. The reason fades in on hover or keyboard focus without changing row height.
- The reorder affordance is three equal-width horizontal bars at the far right, subtly tinted blue, green, and pink. Inactive ellipsis menus are removed.
- The compact remove control is a 42px muted-coral circle with a 13px X and no visible text. Its accessible name remains `Remove {track title}`.
- A swiped row and the revealed action area share one uninterrupted background. There is no seam, translated-row shadow, button shadow, or border around the revealed surface.

## Locked interaction and motion

- Reordering starts only from the three-line handle. Pointer drag and Arrow Up/Down reorder the same track list.
- Swiping begins from the row body. The X appears while the gesture is still moving, and its coral surface stretches horizontally in proportion to the reveal distance.
- Releasing below 65% keeps the track and, after a meaningful short swipe, settles to the compact X. Reversing or cancelling the gesture closes it.
- Crossing 65% of the rendered row width arms removal; releasing while armed removes the track. The threshold is based on the current row width, not a fixed pixel value.
- One-finger pointer/touch drag and two-finger horizontal trackpad input share the same progress and 65% threshold. Dominant vertical wheel input continues scrolling and never begins removal.
- A settled X uses a 420ms pop-and-settle bounce. Reduced-motion mode removes the bounce while preserving the final state and all status copy.
- Removal and reorder both expose a single-level Undo for exactly three seconds, with a visible countdown. Undo restores the original track and position. A newer mutation supersedes the previous Undo window.
- Keyboard users can reorder from the handle, reveal the X with Delete/Backspace, close it with Escape, activate removal from the button, and reach Undo normally.

## Responsive and accessibility behavior

- At desktop widths of 1020px and above, the 468px rail remains persistent beside the conversation.
- Below 1020px, the same content becomes a nearly full-height sheet. Artwork, ordering, swipe progress, the 65% threshold, sticky actions, and three-second Undo remain unchanged.
- Every meaningful result is announced: moved position, removal, Undo completion, expiry/conflict recovery, and failed persistence.
- Color and motion never carry the state alone. The growing control, row movement, accessible label, static status copy, and countdown preserve the reading without animation.
- This approval covers the existing light tape-and-glass surface. No separate dark-theme treatment is approved.

## Rejected directions

- Corner canvas, bottom deck, and detached focus card: they separated arrangement from the mix and did not feel native to the conversation.
- Separate Talk/Mix workspace and artwork shelf: they introduced another mode instead of making the right rail useful.
- A narrow sidebar with numbers or repeated artwork and inactive dots: weak identification and affordance.
- A visible `Remove` label, oversized X, pill at rest, very bright red, or dark burgundy: too loud or too heavy for a repeated row action.
- A differently coloured reveal gutter, shadow, divider, or border: made the action look layered underneath instead of emerging from the row.
- Revealing the X only after release and requiring a three-finger trackpad gesture: insufficient feedback and unnecessary input friction.

## Implementation boundary

- Expected web owners: `web/src/components/QueuePanel.tsx`, `web/src/App.tsx`, `web/src/api/client.ts`, `web/src/components/Icons.tsx`, and `web/src/styles.css`.
- Add component, API-client, optimistic-state, timer, pointer/touch, horizontal-wheel, keyboard, conflict, reduced-motion, and responsive regression coverage under `web/src/`.
- The existing `POST /sessions/:id/queue-ops` contract already supports versioned `move` and `remove`. Reorder Undo can submit the inverse move.
- Removal Undo still needs an implementation decision: either delay the server remove until the three-second window expires or add a versioned restore operation in `server/src/dj/contracts.ts`, `server/src/dj/queue-store.ts`, and `server/src/routes/sessions.ts`. The approved immediate visual removal and three-second restoration behavior may not change whichever path is chosen.
- A queue-version conflict must replace optimistic state with the authoritative returned queue, close the stale Undo window, and explain that the mix changed elsewhere.
- No visual or interaction details remain unresolved. Track menus remain outside this approval.

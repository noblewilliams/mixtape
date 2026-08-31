# Web composer focus and send-control approval

- **Approved:** 2026-08-31
- **Board:** `docs/mockups/2026-08-31-web-composer-focus-state.html`
- **Winning direction:** a compact composer whose outer shell carries the colorful focus border, paired with a visually quiet straight-up send arrow.
- **Supersedes:** the raised plum send button and generic input focus outline shown as the current state in the approved board.

## Locked behavior and appearance

- The outer composer container owns the two-pixel horizontal five-color gradient when any control inside it has focus. The input itself remains borderless and has no outline, tinted fill, halo, or lift.
- The composer is 48px tall with slim one-pixel vertical padding, a 10px left shell gutter, and a 5px visual inset between the send target and the right edge.
- The send control uses a centered straight-up arrow. At rest, no button background is visible.
- Hover and keyboard focus both reveal the same subtle plum background with no border or focus ring.
- The visible hover/focus surface is 32px square while the semantic button retains a 44px square target and the accessible name `Send message`.
- Disabled states keep the arrow subdued and do not show the plum interaction background.
- Focus does not change the composer's measured size or move surrounding content.
- Desktop input text is 13px. Mobile input text is 16px to avoid automatic browser zoom.
- Reduced motion keeps the final focused state unchanged and removes the short color/background transitions.

## Rejected directions

- A raised 40px plum send button: too visually dominant beside the input.
- A diagonal send arrow or paper-plane glyph: less direct than the approved straight-up arrow.
- A send-button keyboard border: added unnecessary chrome; the subtle plum background is the approved focus cue.
- A generic input outline, inner gradient, tinted focused fill, halo, or lift: makes focus feel layered rather than belonging to the composer shell.
- Wider internal gutters and a 52px field: made the composer feel padded and visually heavy.

## Responsive and platform behavior

- Desktop and mobile share the same shell, gradient border, arrow, interaction states, and 44px button target.
- Mobile alone raises the input text to 16px and retains safe-area spacing supplied by the surrounding composer area.
- No intentional theme variant is approved; this record covers the existing light tape-and-glass application surface.

## Implementation boundary

- Expected owners: `web/src/components/Conversation.tsx`, `web/src/components/Icons.tsx`, and `web/src/styles.css`.
- Add focused component and style regression coverage under `web/src/`.
- No unresolved visual or interaction details remain.

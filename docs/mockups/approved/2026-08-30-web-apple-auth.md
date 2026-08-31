# Web Apple authentication approval

- **Approved:** 2026-08-30
- **Board:** `docs/mockups/2026-08-30-web-apple-auth-states.html`
- **Winning direction:** compact centered tape-and-glass authentication surface with a single uninterrupted gradient.

## Locked behavior and appearance

- No divider, rail, or separate background between the message and sign-in areas.
- The darker cool-blue portion spans roughly 60% of the surface before transitioning into the lighter warm end.
- The primary handwritten message is deliberately large; supporting text remains restrained.
- The cassette and its moving hubs carry the loading state. Reduced motion keeps the hubs still and relies on the status text.
- Continue with Apple is a compact black pill that hugs its content, keeps a 44px target, and uses the Apple system-font stack.
- Authentication errors appear inline without replacing or moving the primary control.
- Desktop uses a centered compact two-column surface. Mobile stacks the same content without introducing a dividing line.
- Large-text layouts may grow vertically but must not clip the cassette, status, or Apple control.

## Rejected directions

- Full-width authentication shell: felt too stretched and less intentional.
- Dark left rail with a visible divider: made the two sides feel like separate containers.
- Subtle evenly distributed gradient: did not give the darker side enough presence.
- Wide, lightly rounded Apple button: looked generic and carried too much visual weight.

## Implementation boundary

- Expected owners: `web/src/components/AuthGate.tsx`, `web/src/styles.css`, `web/src/lib/auth-client.ts`, and `web/src/main.tsx`.
- The browser redirect is powered by Better Auth; the real Apple callback remains a deployed-HTTPS smoke test because Apple does not accept localhost return URLs.
- The native Flutter Apple ID-token path remains separate and must keep using the iOS bundle-ID audience.

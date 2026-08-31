# Web Google authentication and account-linking approval

- **Approved:** 2026-08-31
- **Board:** `docs/mockups/2026-08-31-web-google-auth-account-linking.html`
- **Winning direction:** equal compact Apple and Google choices, with explicit account linking from the existing account area.
- **Supersedes:** the single-provider control boundary in `docs/mockups/approved/2026-08-30-web-apple-auth.md`; the underlying tape-and-glass authentication surface remains locked.

## Locked behavior and appearance

- Apple and Google are equal Mixtape login methods; Apple Music authorization remains a separate post-login connection.
- Desktop keeps both compact provider pills on one row. Mobile stacks them with a tight 6px gap.
- The last successfully used login method is marked with a written `last used` cue. The cue is not communicated by colour alone and is available to assistive technology.
- Provider redirecting keeps the cassette loading grammar, disables both login controls, and names the provider in the live status.
- A same-email provider that is not linked never merges silently. Recovery copy sends the listener back through their usual method, then to Account for explicit linking.
- The existing sidebar identity area opens a centered Account dialog titled `Ways to sign in`.
- Provider rows show connected/not-connected state and the provider account email when available. Linking requires that provider's OAuth confirmation.
- A provider may be unlinked only while at least one other login method remains.
- The Account dialog close glyph is visually flush with no visible container while retaining an accessible hit target.
- Reduced motion keeps the cassette hubs still and relies on provider-specific status text.

## Rejected directions

- Silent same-email linking: too easy to merge identities without clear user intent and unreliable when Apple uses a private-relay email.
- A separate onboarding step for Apple Music: login and music-library permission should remain independent and requested at the action boundary.
- Wide generic provider buttons or a boxed provider card: too visually heavy for the approved compact authentication surface.
- A visible rounded container behind the Account dialog close glyph: added unnecessary chrome.

## Implementation boundary

- Expected web owners: `web/src/components/AuthGate.tsx`, `web/src/components/Sidebar.tsx`, a focused account dialog component, `web/src/lib/auth-client.ts`, and `web/src/styles.css`.
- Expected server owner: `server/src/auth/create-auth.ts`, with Google client credentials supplied as Worker secrets.
- Store only the provider identifier (`apple` or `google`) for the last successful login method in local browser storage. OAuth state, provider tokens, emails, and profiles are not part of this preference.
- Google production callback: `https://miixtape.netlify.app/api/auth/callback/google`.
- Unresolved deployment detail: production activation waits for a Google OAuth web client ID and secret.

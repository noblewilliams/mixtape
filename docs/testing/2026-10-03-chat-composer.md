# Shared chat input validation — 2026-10-03

- Home and Conversation share PromptComposer. Chat uses its existing scoped draft cache.
- Playlist and Shape sit inside the input under the text; Shape displays the current saved curve or the draft override.
- Browser inspection of `/qa/chat-composer.html` uses labelled synthetic data and production components. Desktop and 390×844 checked; document width was 390 and textarea computed `resize` was `none`. Shape opens with the current curve selected.
- Mocked recording/transcription tests cover editable voice text in both Home and chat, cancellation, denied permissions and cleanup. No real microphone/backend acceptance claimed.
- Adversarial review found sent drafts could survive navigating away during a request; fixed by clearing at dispatch, with regression coverage.
- Full web suite: 462 passed, 1 skipped.
- Focused App, Conversation, HomeComposer and EnergyJourney tests: 38 passed. Production build and whitespace check passed. Existing Vite bundle-size advisory remains.
- Screenshot: `2026-10-03-chat-composer.png`.

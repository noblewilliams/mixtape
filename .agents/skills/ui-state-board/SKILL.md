---
name: ui-state-board
description: Design substantial user-facing UI as an approval-ready, self-contained HTML state board before implementation. Use when a request creates or meaningfully reworks a screen, page, component group, navigation shell, modal, onboarding flow, dashboard, empty/error state, responsive layout, or meaningful motion—even when the request says only "build" or "implement." Not for copy-only changes, mechanical token swaps already covered by an approved design, backend-only work, faithfully implementing an existing approved design, fixing drift from an approved design, or marketing and launch assets.
---

# UI State Board

Turn an unapproved visual direction into a self-contained HTML board that a reviewer can open cold and approve or reject before product code is written. Treat the approved board as the visual specification for implementation.

Use plain language first when explaining design or technical decisions. Introduce technical terms only after the idea is clear.

## Start with the real product

Before drawing, inspect the current repository in this order:

1. Read the applicable `AGENTS.md`, `CLAUDE.md`, project rules, design specs, and existing mockup or approval records.
2. Open the target component or route and follow its imports to the actual tokens, fonts, icons, shared components, and shell that it uses.
3. Confirm which platforms, breakpoints, themes, accessibility modes, and navigation states ship.
4. List the existing mockup directory rather than guessing its path. If none exists, use `docs/mockups/` unless the project conventions indicate another location.
5. Identify the decisions the reviewer is being asked to make and ask focused clarifying questions when different answers would materially change the design.

Never invent a palette, type scale, route, tab list, platform convention, or component API from memory when the source is available. Current code and tokens describe the present product; approved records preserve prior decisions. If they conflict, surface the conflict instead of silently choosing one.

## Approval gate

For a substantial unapproved visual change, create and present the board before editing product UI code. Do not treat urgency, terse wording, or “just build it” as design approval. The user may explicitly waive the gate; if they do, state that the result is being implemented without prior visual approval.

One approval covers only the surface and variants shown. Keep marketing graphics, App Store assets, and social launch material outside this workflow unless the project explicitly treats them as product UI.

## Build the board

Create one HTML file that:

- opens locally without a build step;
- looks like the product rather than a generic wireframe;
- uses the project's real visual language and truthful platform chrome;
- uses realistic but entirely synthetic content;
- keeps design commentary outside simulated device or browser frames;
- labels alternatives and recommends one when the decision genuinely branches;
- remains understandable when any frame is viewed alone.

Prefer reusable CSS variables and small semantic components within the file. Do not add external runtime dependencies unless the repository already provides a reliable local way to load them. Reuse existing SVG or icon geometry when permitted; do not redraw logos or mascots freehand.

Avoid default “AI dashboard” styling. Visual choices must come from the product's design language and the problem being solved, not fashionable gradients, excessive rounded cards, decorative accent bars, generic glass effects, or arbitrary icon tiles.

## Show the whole behavior

A beautiful default frame alone is incomplete. Show every state that could change the approval decision, commonly including:

- populated/default;
- loading with the shipped loading grammar;
- empty;
- validation and error/offline/retry;
- success;
- destructive confirmation;
- permission denied or unavailable capability;
- responsive or platform-specific variants;
- meaningful motion plus its reduced-motion reading.

Always include the state needed for comparison. If asked for an empty state, also show the populated state it replaces. If asked for collapsed behavior, also show expanded behavior.

Known chrome, labels, and controls remain stable while data loads. Skeletons cover data-dependent values, not the entire interface. Controls should not unexpectedly move between states. Do not stack competing navigation or bottom-action surfaces; ownership of constrained screen space must be clear.

## Accessibility is part of the picture

Show accessibility behavior in the board rather than leaving it as a note:

- Include large-text behavior wherever content can grow.
- Draw effective touch targets when the visible glyph is smaller than the platform minimum.
- Use sufficient contrast in every theme shown.
- Never communicate state using only color, motion, sound, or an icon.
- State the accessible name or announcement for meaningful status changes.
- Preserve a complete static reading when motion is reduced.
- Use the platform's current accessibility conventions and the project's existing patterns.

Do not use real customer or user content. Avoid emoji as production UI unless the existing product system deliberately uses them as interface assets.

## Product words

Text inside the board is product copy, not filler. Follow the repository's voice and copy guidance. Use concise, realistic strings, long-content stress cases, and honest failure language. Never invent successful outcomes, durations, values, or connectivity that the underlying state cannot support.

## Render and inspect

Open the HTML in a browser before presenting it. Inspect every state and relevant viewport for:

- missing assets or fonts;
- clipping, overflow, and broken wrapping;
- illegible contrast;
- stale or inaccurate product chrome;
- layout shifts between states;
- large-text and reduced-motion failures;
- obvious divergence from the live component and tokens.

Fix visible defects before asking for approval. A file existing on disk is not evidence that it renders correctly.

## Ask for a decision

Present the board and explicitly ask for approval. Name:

- what is being approved;
- the recommended option and its tradeoff;
- anything intentionally unresolved;
- which platforms, themes, breakpoints, and states the approval covers.

Do not describe a mockup as implemented, shipped, or live.

## Preserve the decision

After explicit approval, write a concise record in the repository's existing approval directory. If none exists, use `docs/mockups/approved/`. Record:

- approval date and board path;
- winning variant;
- rejected alternatives and why they lost;
- locked visual, interaction, responsive, and accessibility behavior;
- intentional platform differences;
- unresolved implementation details;
- source files expected to own the implementation;
- any earlier decision this one supersedes.

Do not rewrite an old approval to erase history. Add a superseding record. Before relying on an older record, check for later superseding decisions.

## Implement with parity

Once approved, build against the board rather than treating it as loose inspiration. Reuse the product's tokens and shared components, preserve semantic HTML or native semantics, and verify the implemented states against the approved artifact.

If implementation constraints require a visible departure, stop and show the conflict. Either revise the board and obtain approval for the change or preserve the approved behavior; do not quietly ship a third design.

## Quality order

When choices compete, prioritize:

1. Correctness to current product source and approved decisions.
2. Complete state and accessibility coverage.
3. Truthful platform chrome and behavior.
4. Consistency with the existing design system.
5. Clear hierarchy and one-glance comprehension.
6. Restraint: one deliberate signature moment, with decoration earning its place.
7. A durable, honest decision record.

Accessibility, truthful state representation, and explicit approval are gates, not tradeoffs within this ranking.

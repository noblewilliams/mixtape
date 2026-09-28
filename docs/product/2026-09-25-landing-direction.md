# Mixtape landing page — proposed content and motion

September 25, 2026. Section proposal with founder-approved visual direction and call-to-action hierarchy. First implementation completed September 27 in `landing/`; local browser review and build checks are recorded in `landing/README.md`.

Implementation note: the first version keeps the desktop demo in normal document flow with selectable steps instead of pinning it. GSAP provides scroll-linked parallax and colour transitions; Motion provides the interactive transitions. Synthetic samples are explicitly labelled. Download opens an honest browser-access fallback until the real mobile distribution URL is supplied. Publication is pending.

## Positioning

Your personal DJ for the moment you are in. Describe what you want, refine the mix together, and play it or save it as a playlist.

The strongest differentiator is the conversation grounded in the listener's taste. The cassette is the visual signature. The page should make both understandable within its first screen.

## Reference interpretation

The supplied Bird screenshot is visual inspiration, not product requirements or instructions. Borrow its spacious light canvas, split hero, large editorial headlines, asymmetric image blocks, saturated diagonal colour, and simple FAQ. Its fundraising copy, statistics, partner grid, and repeated sections have no place in Mixtape's story.

Translate the racing car and astronaut into Mixtape's own subject: a richly rendered cassette, music artwork, and moments of listening. The reference's rainbow light connects directly to the app's existing prism stripes. Keep the established wordmark; explore a narrow editorial display face for marketing headlines separately from the native app's SF typography. Headline font selection is a proposal, not a change to app tokens.

## Five sections

### 1. Hero — “What should this moment sound like?”

Copy: “Tell Mixtape the mood, the moment, or the music on your mind. Your personal DJ takes it from there.”

Desktop: restrained navigation and copy on the left; a large cassette in a deep blue scene crossed by prismatic light on the right. Add three selectable examples: “A late drive home”, “People over for dinner”, and “Something to get me moving”. Selecting one changes the tape label, colour, and sample mix preview. Keep the headline stable so it remains readable.

Primary action: **Open in browser**, leading to the web app. Dedicated secondary button: **Download the app**, with visible supporting copy: **Recommended for Apple Music library sync.** Keep this recommendation beside the button, not hidden in a tooltip. “See how it works” can be a quiet text link to the demonstration. Use a verified mobile distribution destination when wiring the download action.

Motion: coordinated text and cassette entrance, gentle reel movement, light passing over the tape shell, restrained pointer tilt on suitable devices, and separate foreground/background scroll speeds. Label the selectable preview as an example; it does not call the DJ or imply instant generation.

### 2. Product demonstration — “A little direction. A mix that feels right.”

One continuous three-step demonstration, rather than a separate how-it-works section plus a feature grid:

1. Describe the moment: “Dinner with friends. Warm, familiar, nothing too loud.”
2. Shape the mix: “A little more upbeat.” Show an example conversation and the corresponding song arrangement changing.
3. Play now, or create a playlist: show the two distinct outcomes, using the Apple Music path for the playback demonstration.

Desktop: a short pinned product scene with the explanation advancing alongside it. A visitor can also select each step directly. Phone: three compact stacked steps and a tappable preview, with no long pinned region.

Motion: prompt becomes a conversation, songs enter the arrangement, a refinement moves selected rows, and the cassette settles into the player. Use synthetic examples and actual interface components or faithful captures. Explicitly identify this as a product demonstration; do not suggest that it generated a personalised result for the visitor.

### 3. Personalisation — “Your taste is the starting point.”

Three asymmetric editorial blocks, echoing the reference's image-led grid:

- **Start with music you love.** Connected/imported music and existing playlists provide context. Illustrate an existing playlist becoming inspiration for a new mix.
- **Tell it what stays with you.** Preferences can be remembered; the listener can inspect and forget them. Show a short example remembered preference, not broad claims about invisible tracking.
- **Make it yours.** Ask for changes, reorder songs, remove a track, and return to saved mixes. Show the arrangement responding to a visitor's sample action.

Motion: artwork at different depths, a playlist resolving into a tape, preference text appearing after an explicit sample action, and track rows moving into their new positions. Energy-shape controls can be added here after their release status is confirmed; they do not need a sixth section.

### 4. Music services — “Bring the music you already love.”

A concise two-column explanation with accurate provider marks:

- **Apple Music:** connect your library; play mixes and create playlists through the implemented Apple Music path. Recommend the native app for library sync, with a dedicated **Download the app** action and the copy “For the best Apple Music library-sync experience, use the app.” Browser access remains available; do not imply that library sync is native-only. Explain the subscription requirement alongside playback, using verified launch copy.
- **Spotify:** bring exported playlists/listening data. Refresh through a new export. Outputs use Spotify links, copied lists, or the supported transfer handoff. Do not promise live Spotify sync, integrated Spotify playback, or automatic Spotify playlist creation.

The Spotify import workflow exists in code, but release and real-file acceptance remain recorded as open. Its public availability wording must match the actual launch build.

Motion: imported artwork gathers into a mix, and the selected provider explanation transitions in place. Both explanations remain reachable without hover. This is functional compatibility information, not a partner endorsement wall.

### 5. Questions and closing invitation

Compact FAQ with four initial questions:

- How does Mixtape learn my taste?
- Do I need Apple Music, and what can I do with Spotify?
- Will this change my existing playlists?
- Can I see and remove what the DJ remembers?

Then a full-width prism scene: “Your next moment deserves its own mix.” Repeat **Open in browser** and **Download the app**, retaining the Apple Music sync recommendation beside the download action, and provide real support/privacy/terms destinations when available. No invented pricing, testimonials, user totals, or partnerships.

Motion: smoothly expanding FAQ rows with a colour treatment inspired by the reference; the final prism expands across the footer as it enters view. Keyboard focus and open state remain clear without animation.

## Motion and responsive rules

Use one repeating visual idea: light travels through a cassette and becomes a mix. Give each section its own choreography while preserving that connection.

- GSAP/ScrollTrigger owns the large page sequences: hero parallax, short pinned demonstration, prism transitions. See https://gsap.com/docs/v3/Plugins/ScrollTrigger/.
- Framer Motion / Motion for React owns interactive component transitions: example selection, row changes, menus, and FAQ. Keep animation ownership separate so two systems do not write transforms on the same element. See https://motion.dev/docs/react-scroll-animations.
- Retain native scrolling. Keep body text stationary during reading; animate scenes around it.
- Stop decorative loops offscreen; provide a motion toggle and respect reduced-motion preferences with a complete static composition.
- Mobile uses the same story and assets, with shorter travel distances, no hover dependency, fewer simultaneous layers, and no long pinning. Tablet keeps asymmetry where space permits.
- Test at 360, 390, 768, 1024, and 1440 pixels wide, plus short laptop height, keyboard navigation, large text, and reduced motion. Preserve meaningful content before animation JavaScript loads.

## Feature evidence and publication boundaries

This review covered product documents, web composition and components, native screen inventory and current screens, and API feature routes. It did not perform an authenticated production smoke or verify distribution availability. Older documents call web a placeholder; current `web/src/RootApp.tsx` and `web/src/App.tsx` show an authenticated React application.

| Feature family | Evidence in current repository | Landing treatment |
| --- | --- | --- |
| Prompt, conversation, refinement | Web Conversation/App; native Home/Chat; sessions routes | Main story |
| Arrangement, reorder/remove, track reasons | Web QueuePanel; native QueueScreen | Demonstration |
| Apple playback and playlist creation | Web App/MusicKit/player; native playback/queue | Main outcome; verify launch environment |
| Playlist inspiration and browsing | PlaylistAttachment/PlaylistBrowser; native playlist screens; playlists routes | Personalisation block; release checks remain in backlog |
| Taste interview and explicit memory | InterviewDialog/MemoryControls; native interview/memory; interview/memories routes | Supporting benefit |
| Spotify imports and outputs | Web import parsers/ImportPanel/QueuePanel; native import screens | Explain export-based workflow; confirm rollout before claiming availability |
| Mix collection and archive | Web session controls; native Mixes/Chat | Supporting visual, no dedicated section |
| Version restore, energy journeys, playback learning, routines | Components/screens/routes exist; backlog records migration/release gates | Hold detailed public claims until release is verified |
| Voice input | Native implementation and September 18 decision; transcription release gate recorded | Optional later demo, not initial headline promise |
| Existing-playlist editing | Native edit screen and separate server draft/apply paths | Omit from main story until write-path release acceptance; never imply silent source overwrite |
| Private blends and taste twins | Planned in selected feature program; native Together is a future entry | Omit from launch feature list |
| Account linking, imports management | Account and source controls | Product essentials; FAQ/support rather than feature sections |

Key references: `docs/product/vision.md`, `docs/decisions.md`, `docs/backlog.md`, `docs/product/2026-09-09-mobile-design-inventory.md`, `web/src/App.tsx`, `web/src/components/`, `client/lib/presentation/screens/`, and `server/src/routes/`.

## Approved direction and remaining wiring

The founder approved the reference's light editorial layout, vivid rainbow imagery, and Mixtape cassette/prism identity. Browser entry is the primary action, with a dedicated native download button explicitly recommended for Apple Music library sync. Preserve this hierarchy in the hero, navigation, and closing invitation; on narrow screens stack the actions with the recommendation directly under the download button.

Exact browser and mobile distribution URLs still need verification when wiring actions. Keep this marketing surface independently loadable from the authenticated app; do not replace `web/` as though it were still a placeholder.

## Founder revision — September 28, 2026

Supersedes the first implementation layout: remove top navigation; make the hero a flush 50/50 split; reduce copy; advance the sticky demo through three steps with scrolling. Keep accessible step controls and ordinary flow when motion is disabled or the viewport is too short. Replace personalisation/services duplication with Apple sync, Exportify, deeper-history and DJ-memory cards. Apple archive import remains upcoming. Add a faded situations marquee, consistent right-arrow hover without button movement, rotating accents, raw app tape SVG assets, and a larger colourful footer extending to the bottom with sibling-dimming navigation hover.

Follow-up feedback: remove the situations marquee and visible motion controls, let the desktop hero fill the viewport, and reduce the cassette within a broader prism scene. Stick the new “From a feeling to a mix” heading with its demo. Replace the large footer lettering with the existing raw tape illustration. Device reduced motion and short-screen fallback remain.

Further founder feedback: vertically centre the full sticky group, reduce the scroll runway, and match the app’s unboxed message alignment. Replace the large face-on footer tape with a single dense row of closet spines. Preserve app case proportions; omit cabinet/shelf materials and align the case bottoms with the page edge.

Latest demo: keep one conversation across scroll steps. Type the listener message, show a brief thinking state, type the DJ reply, then reveal/update the mix. Fast scrolling queues the second exchange after the first; reduced motion shows content immediately. Final “Play mix” and “Create playlist” actions open the actual app because sample songs are illustrative. Footer closet now fills the full width, lifts on hover, and uses unique titles and varied case/label colours. Four focused tests cover entry points, reduced motion, retained conversation and timer sequencing/cleanup.

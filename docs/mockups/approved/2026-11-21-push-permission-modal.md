# Approved: the Mix ready notifications ask

Approved November 21, 2026. The founder replied "Approve r3" to the third
revision of the board:

- [revision 1](../2026-11-21-push-permission-modal.html): a bottom sheet.
  The founder asked for a pop-up modal with a blurred overlay instead of a
  bottom sheet, and for shorter failure-notification copy.
- [revision 2](../2026-11-21-push-permission-modal-r2.html): a centred
  pop-up over a blur. The founder asked for a much smaller illustration,
  every line centred, smaller type (especially the title), and more space
  between the illustration and the text.
- [revision 3](../2026-11-21-push-permission-modal-r3.html): approved as
  drawn.

Spec: `docs/superpowers/specs/2026-11-21-durable-mix-turns-design.md`
(founder answer 3).

## Winning variant

- **The art is I1:** the full cassette (`CassettePainter`) at 108 pt wide,
  tilted −4°, with its hubs turning. A small "Your mix is ready · <mix
  title>" notification, drawn with the reel crop of the app icon, rises out
  of it every 3.2 s. It is decorative and hidden from VoiceOver.
- **The copy is as drawn.** "Pressed" was offered as an alternative and not
  taken.
  - Title: "Want a ping when it's ready?"
  - Body: "Mixes take up to a minute. Lock your phone, get on with your day,
    and we'll tell you the moment yours is ready." On the web, "Lock your
    phone" becomes "Close the tab".
  - Primary: the paper pill "Turn on notifications". It is the only thing
    that brings up the system prompt.
  - Secondary: "Not now".
- **After Allow** on "Making your mix", the screen gains one quiet line
  under the step line: a bell, then "We'll ping you when it's ready." Home
  adds nothing.

## Locked behaviour

- **The container is a centred pop-up,** 22 pt in from each side, with 30 pt
  corners on the sheet surface (`#fbfaf8` light, `#1c1a22` dark).
  - Behind it, the screen is blurred by 16 pt, with a light tint (about 16%
    light, 32% dark).
  - Tapping the overlay closes it, like "Not now".
  - There is no grab handle.
  - The app has no centred modal yet, so this becomes a new shared widget
    (`MixtapePopup`).
- **Type and spacing:**
  - Everything is centred.
  - The title is about 18 pt bold. The body is about 13.5 pt, in the smoke
    colour.
  - The pill is 50 pt tall, and "Not now" has a 44 pt target.
  - There are about 18 pt between the art and the title.
- **When it shows**, once per install. The flag is set the moment it
  appears, however it is closed.
  - A new listener sees it about 3 s into their first prompt, over "Making
    your mix" or the chat's working state.
  - A listener who has just signed up sees it on Home.
  - An existing listener who has never been asked sees it on Home.
  - It is never stacked on the AI-consent sheet.
- **When the OS has already decided,** it never shows. Already allowed: it
  registers silently. Denied: it never shows.
- **Don't Allow, Not now and a tap outside** all just close it, and there is
  no second ask. You → Settings gets a "Mix ready notifications" row:
  - On: a switch, on.
  - Off after "Not now": a switch, off. Turning it on brings up the system
    prompt.
  - "Off in iOS Settings" after a denial: no switch, just a link to iOS
    Settings.
- **At 200% text** the art drops to the cassette alone (about 80 pt), the
  pop-up grows to the screen's height and scrolls inside, and the buttons
  stay reachable at the bottom.
- **Reduced motion:** the hubs stand still, and the notification sits
  still above the tape.
- **VoiceOver:** "Want a ping when it's ready?, heading", then the body,
  then the two buttons.
- **Dark mode:** the dark surface with a stronger tint. The cassette keeps
  its own colours.

## Intentional platform differences

- **Web:** the same pop-up and blur. Its buttons are the web's quiet text
  buttons, centred together. "Once" is remembered in this browser. It is
  only offered where `PushManager` exists: on iPhone, the Home Screen web
  app, and never a Safari tab.

## Rejected

- **The bottom sheet** (r1): the founder wants a pop-up with a blurred
  overlay.
- **The large art and big title** (r1, r2): too dominant.
- **I2, the cassette buzzing:** it explains less than showing the actual
  notification, and the shake competes with the turning hubs.

## Unresolved for implementation

- **`MixtapePopup`:** its exact blur implementation in Flutter
  (`BackdropFilter` under the route, or a hosted UIKit blur on iOS 26 to
  match Liquid Glass), and its entry and exit motion. Default: a 200 ms
  fade and scale from 0.96. Reduced motion: a fade only.
- **Interplay with the quick fix:** if the parallel quick fix asks for
  notification permission another way, this pop-up replaces that ask once
  both are in one build.

**Resolved in the build (2026-11-22, `da9ad3f`, `2fb81a8`):**

- **Blur:** a Flutter `BackdropFilter` (16 pt, light tint) over the tab
  navigator. The native Liquid Glass dock is a hosted UIKit view and is not
  blurred under it. Web: the blurred overlay variant of `ControlModal`.
- **Motion:** a 200 ms fade and scale from 0.96; a fade only under reduced
  motion (`MixtapePopup.transition`).
- **The quick fix's ask:** removed. The quick fix's local "Your mix is
  ready" now only reads the permission, so this pop-up is the single ask
  (the same OS permission covers the local ping and the push).
- **"Once":** the `push_ask_shown` flag lives in the Keychain, so it
  survives a reinstall: once per device, not per install. Web keeps it in
  `localStorage` (`mixtape.pushAsked.v1`), once per browser.

## Expected owners

- iOS:
  - A new `widgets/foundation/mixtape_popup.dart`.
  - A new `widgets/push_permission_popup.dart`.
  - Its triggers in `first_run/making_screen.dart`, `chat_screen.dart` and
    `home_screen.dart`.
  - The You row in `tabs/you_tab.dart`.
- Web:
  - A new `components/PushPermission.tsx` over a blurred overlay variant of
    `ControlModal`.
  - Its triggers in `Making.tsx`, `Conversation.tsx` and `Home.tsx`.

# Approved Add your music redesign, Library sources and official service icons

Approved November 21, 2026, over four revisions of the board:

- [revision 1](../2026-11-21-add-your-music-restyle.html): the founder chose
  L1 (flush rows), then asked for nicer service, tick and warning icons, and
  for a real redesign of Add your music.
- [revision 2](../2026-11-21-add-your-music-restyle-r2.html): the founder
  asked for smaller icons and tighter sections, using the brands' real files
  instead of drawn marks.
- [revision 3](../2026-11-21-add-your-music-restyle-r3.html): the founder
  asked for more space under the toggle, Sync as an icon, the Apple file
  inside the how-to fold, and a better toggle.
- [revision 4](../2026-11-21-add-your-music-restyle-r4.html): the founder
  replied "t1".

The rest of r4 is approved as drawn. The Library section is r3's, unchanged
in r4.

It started from TestFlight 1.1.1 (14). There, "Add your music" on Library
opened Your music, not Add your music. Add your music "looks shabby", and so
do the Apple Music and Spotify sections at the top of Library. It ships as a
Shorebird patch to 1.1.1+14, so every change is Dart only.

## Winning direction

- **One way in.**
  - The Library title row carries a small glass "Add music" pill beside
    "Library", and it opens Add your music.
  - Your music (`MusicSourcesScreen`) is retired. Its Remove actions move onto
    Add your music, and its Browse playlists button is dropped because Library
    lists the playlists.
- **Library sources are two flush rows.**
  - Each row has a 22 pt official icon, the name, the status on the right and
    a chevron. Rows are 44 pt tall.
  - Each row opens Add your music on that service's segment.
  - At 1.3× text and above, the status drops under the name and the icons
    grow to 28 pt.
- **Official icons.**
  - Apple Music is Apple's colour icon, from the Apple Music Icon 2020 pack on
    Apple's identity guidelines page.
  - Spotify is Spotify's one-colour icon, from the 2024 icon pack on
    developer.spotify.com. It is black on light and white on dark, because
    Spotify allows its green icon only on pure black or white.
  - The originals are kept in `docs/brand/`. The app embeds their SVG source
    as Dart, because patches can't carry assets.
  - Neither icon is ever tinted or greyed. A service that isn't added keeps
    its icon, and the words "Not added" carry the state.
- **Filled status glyphs.** The ok status is a green filled circle with a
  white check. The warning is an amber filled triangle with a white "!". The
  words keep their ok and warn inks.
- **Add your music.**
  - **Toggle (T1):** the native Liquid Glass segmented control (the Mixes
    one), hugging the left margin, with 22 pt below it.
  - **Header:** one line, with a 32 pt official icon, the service name,
    "1 of 2 added", "All in", "Not added yet" or "Syncing…", and a small
    two-segment meter.
  - **Checklist:** two steps per service.
    - Apple Music: Library, then Listening history (optional).
    - Spotify: Saved music, then Listening history (optional).
  - **A done step** is one line, with its actions at the right:
    - Apple Library: a sync icon (44 pt target, "Sync Apple Music").
    - Apple history: "Replace" and "Remove".
    - Spotify: "Import again" and "Remove".
  - **The current step** is open. The Apple history step shows one line and
    a "Get your Apple file" fold. The fold holds the request steps, then the
    Choose button and its note.
  - **A failed sync** shows an amber "!" disc and words, and retries with the
    same sync icon.
  - **Never synced:** the tape "Sync Apple Music" is the one primary button.
    History waits, with a small "Choose file" action.
  - The Exportify buttons stay on opposite edges (smoke round five).

## Rejected

- **L2, refined halves:** the two statuses still compete for one line.
- **Drawn brand tiles (r2) and grey not-added icons:** the founder wanted the
  real files, and both brands forbid recolouring.
- **Single-tone marks on a soft disc (I2):** less recognisable.
- **T2, brand icons inside the toggle segments:** they duplicate the header
  icon, and a drawn toggle isn't the real glass lens.
- **The Apple file button in plain sight (r3):** the founder wanted the
  screen freer.

## Locked behaviour

- The brand icons are decoration and are excluded from semantics.
- Each step is one semantics container, such as "Step 1, Library, done,
  synced 2 November".
- Status never relies on colour alone: there is always a glyph plus words.
- The step copy for both services is unchanged.

## Supersedes

- From the 2026-11-03 Library sources approval:
  - the strip of two halves;
  - the title's "Your music" button;
  - the Add your music status-row layout.
- The 2026-09-18 single-tone mark rule, for these two screens only. Other
  screens keep `AppleMusicMark` and `SpotifyMark` for now.
- The Your music screen (2026-09-04, restyled 2026-09-17).

## Owners

- `client/lib/presentation/screens/tabs/library_tab.dart`
- `client/lib/presentation/screens/spotify_request_screen.dart`
- `client/lib/presentation/screens/music_sources_screen.dart` (screen
  retired, helpers kept)
- `client/lib/presentation/widgets/foundation/brand_icons.dart` (new)
- `client/lib/presentation/widgets/foundation/status_word.dart`

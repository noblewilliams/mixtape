# One platform, fixed mix actions, artist-only mixes

Date: 2026-11-09. Status: approved direction (founder, 2026-11-09), board pending.

## Why

A TestFlight user (screen recording, 2026-11-09) made a mix and could not play
it. Over 45 seconds:

- **Play** opened the app's player, which said "Apple Music could not play this
  song. Check access and your subscription" three times. The native player
  returned `authorization_required` (MusicKit access was never requested; only
  the small Connect Apple Music button asks for it). The client replaced every
  native error with that one line (`playback_controller.dart` `start`).
- The arrow menu (Play here / Play in Apple Music / Play on Spotify) changed
  the whole bar. Choosing Spotify renamed Play to "Play on Spotify", hid Create
  playlist and switched every row to open in Spotify, because
  `mixListensOnSpotify` derives "Spotify listener" from the last menu choice.
- "Play on Spotify" does not play anything: it copies the songs and opens
  TuneMyMusic to build a playlist.
- The conversation strip shows Play only; the arrangement bar adds Create
  playlist. Same mix, two different sets of actions.
- Only "Play in Music" (the system Music app) worked.

The prompt "Cole I can rap to" also produced a mix with 2 J. Cole songs in the
first 9 (Kendrick, Baby Keem, Travis Scott, Childish Gambino filled the rest).
Named artists only seed the pool. Nothing narrows a mix to one artist, and the
curation rule "at most two tracks by any one artist, unless the request is
about that artist" is left to the model.

## Decisions

1. **One primary platform per device: Apple Music or Spotify.** It replaces
   the three-way Play destination. Storage keeps the existing key. A stored
   `here` or `apple_music` reads as Apple Music, and `spotify` as Spotify.
2. **Ask once, on app open, only when unknown.** Known means a stored
   platform, or `chosenService` is `apple`/`spotify`, or an Apple library is
   syncing live. A known service is written silently as the platform. If
   nothing is known, the existing "Where do you listen?" sheet opens once over
   the shell (after first run, never during it). It has two answers and no
   dismiss without one, because the answer decides every mix's actions. The
   first-Play ask (`askService`) goes away. You keeps the setting, now two
   options.
3. **Fixed mix actions, no arrow, identical on the conversation strip and the
   arrangement bar.**

   | Platform | Primary | Secondary | Rows |
   |---|---|---|---|
   | Apple Music | **Play** (becomes **Playing** while on this mix) | **Create playlist** (Apple) | as today |
   | Spotify | **Create playlist** with the Spotify mark (TuneMyMusic handoff) | none | open in Spotify (search when no id) |

   Nothing on the bar changes in response to a tap except Play/Playing. The
   TuneMyMusic explainer sheet stays for the first handoff on a device.
   Its headline "Make it a Spotify playlist" now matches the button.
4. **Play for Apple Music users always works or says why.**
   - Play requests MusicKit authorization itself when it is not determined
     (the system prompt shows on the tap), then starts.
   - If the app's player still cannot start (denied, `playback_failed`,
     `song_unavailable`), the mix goes to the Music app
     (`MPMusicPlayerController.systemMusicPlayer`, the path that worked in the
     recording) with the toast "Playing in Apple Music". No error screen.
   - Only `subscription_required` with no Music-app success shows a message,
     and it names the real cause: "Playing needs an Apple Music subscription."
     Any other start that the Music app also fails says "Apple Music
     couldn't play this mix.", never Apple's raw error text.
   - Native error codes reach Dart intact; the generic line is gone.
5. **A mix asked for one artist is that artist.** The intent gains
   `onlyArtist` (one name), set when the brief asks for one artist's own
   music ("Cole I can rap to", "just Drake", "SZA songs", "J. Cole deep
   cuts"). It is not set for "like X", "X vibes", "artists like X", "in the
   style of X" or for two or more artists. In that mode:
   - the pool is the artist's tracks, matched with `creditedKeys` so features
     count, from the listener's pool plus the shared catalogue;
   - catalogue fill runs for that artist with a larger per-artist allowance;
   - the two-per-artist spread rule is off and curation picks only from that
     pool;
   - when there are fewer tracks than the target, the mix is shorter and the
     DJ says so plainly, never padding with other artists. "Never refuse"
     still holds: a short mix of that artist is a mix.

## Out of scope

- Web (`web/`) mix rail parity. Follow-up once iOS settles.
- Real Spotify playback or a Spotify API playlist. The handoff stays
  TuneMyMusic.

## Tests

- Client: platform resolution (stored value, `chosenService`, live Apple
  source, unknown); the sheet shows once and only when unknown; strip and bar
  render the same actions per platform; no arrow; menu-free bar never hides
  Create playlist for Apple users; Play authorizes then starts; failure falls
  back to the Music app; subscription message.
- Server: intent extraction golden prompts (`only` vs `like`); in only-artist
  mode every queued track credits the artist; short pool yields a short mix
  and an honest reply; multi-artist and "like X" prompts keep today's
  behavior.

# Approved reel loader

Approved November 16, 2026. The founder replied "Approve, build it" to the
revised [board](../2026-11-16-reel-loader.html), after asking for two changes
to the first version:

1. In chat, tilt the reel like today's cassette.
2. In a Mixes row, keep every tape's width and zoom in, rather than show the
   exact logo.

## Why

On 1.1.0 (8), the working cassette's hubs turned but were 7–19 pt wide, so
people saw an illustration and not something loading. The loader now zooms in
on one hub, the way the app icon does.

## Winning variant: A

| Where | Crop (cassette viewBox units) | Size | Hub |
|---|---|---|---|
| Home, "Making your mix" | icon: 108 22 78 78, 23% rounded corners | 112 × 112 pt | 46 pt |
| Mixes row while the DJ works | row: 96 29 100 64, the cassette's own corner | 68 × 44 pt, the same size as every other tape | about 24 pt |
| Chat working line | icon, tilted −0.07 rad like the old cassette | 34 × 34 pt | 14 pt |

- The speed stays at one turn every 1.05 s. The two hubs turn in opposite
  directions, as before.
- A Mixes row uses the mix's own case colour, and swaps instantly back to the
  full cassette when the reply lands.
- Reduced motion: the hub stands still. The words carry the state ("Making
  your mix", "The DJ is on it…", the rotating captions).
- Large text: the art keeps its size, and the copy wraps beside it.
- Copy, live regions and VoiceOver announcements are unchanged.

## Rejected

- **B, the hub centred in a circle:** it looked like a generic spinner rather
  than the app, and a round shape clashed with the rectangular tapes in the
  Mixes list.
- **The first version of A:** a 44 pt icon tile in Mixes rows, and an upright
  reel in chat. Both were revised at the founder's request.

## Not changing

The full cassette stays wherever nothing is loading. First run's "making"
screen keeps its 176 pt cassette.

## Implementation

`CassetteTile` gains a `crop` (`CassetteCrop.icon`, `CassetteCrop.row`) that
`CassettePainter` paints through. The board's notes proposed a separate
`ReelTile`. This is the same picture with one place owning the hub animation
and the reduced-motion rule.

The crops are used in three places:
- `home_screen.dart`: `_StartingState`
- `mix_home_row.dart`: `_tile` while `working`
- `lyric_turn.dart`: `WorkingCassette`

# Approved departure: deleting the playing mix

Approved November 17, 2026: the founder replied "Accept it" when asked whether
a deleted playing mix may hide the mini-player while the music keeps playing.

This supersedes one sentence of board frame S5 in
[the select and delete approval](2026-11-16-select-delete-mixes.md): the
mini-player no longer stays on screen without linking back. When the mix that
is playing is deleted, the player lets go of it the way `release()` does, the
dock's mini-player goes, and playback in Apple Music carries on. Owned by
`client/lib/data/playback/playback_controller.dart` (`forgetSession`) and
`client/lib/presentation/providers/dj_providers.dart`.

**Why:** the mini-player's play and next controls need a mix behind them;
keeping it without one is a bigger change than the delete is worth.

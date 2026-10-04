# Inline mix rename — October 3, 2026

The shared web title editor retains the title's layout footprint while editing.
It uses the same typography and spacing, a transparent background, and a single
bottom rule instead of a bordered field or focus ring. Keyboard guidance stays
available to assistive technology without adding a visible line. Saving/error
feedback remains available, and failed saves retain the draft and Retry action.
Home/Mixes rows retain their cassette and song details during rename.

Validation: focused SessionControls and App.controls tests (9 passed), web
TypeScript/production build, and local synthetic Home preview. Before and after
entering rename, the title block remained at y=370.34375px with root scrollTop=0.
No backend writes or deployment were needed for this presentation change.

Follow-up: clicking the title enters rename directly; cassette clicks open the
mix. Rows without cassette artwork expose opening through the song/time details.
The title and open controls are separate buttons, so rename cannot bubble into
navigation. Updated focused coverage: 27 tests passed across SessionControls,
App.controls, and App.test; the web production build passed.

# Every song earns its place

Date: 2026-11-09. Status: approved direction (founder, 2026-11-09: "Yes, all three").

## Why

A production pressure test on 2026-11-09 (16 prompts and edits, founder account,
Worker `1b56ec3a`) found songs that do not belong in their mix:

- **Genre prompts pad with the library.** A listener with a library is curated
  only from that library (plus a small outside-picks share). When the library
  does not cover the brief, the curator fills the count anyway:
  - "90s r&b slow jams for a dinner date" got Portishead, Radiohead "High and
    Dry", Fugees "How Many Mics" and a skit track; only Sade and Lauryn Hill fit.
  - "rainy sunday reading, soft jazz" got no jazz.
  - "focus music, no vocals" got fifteen vocal tracks, including "Climb Ev'ry
    Mountain".
  - The same handful of artists appears in almost every mix.
- **A named artist in an edit is not enforced.** "swap in some Kendrick" added
  no Kendrick, twice, though Kendrick is in the listener's library. Once it also
  returned a 502 after the swaps had already been saved, with no DJ message.
- **The reply can claim what is not there.** "Frank Ocean and Daniel Caesar"
  was described as anchored by both; it held no Frank Ocean song of his own.
- **Intros, interludes and skits land mid-mix.** Cole "Intro" at 6, Asake
  "Intro" at 4, two Tems interludes near the end.
- **Notes are arc narration, and repeat.** The "two to six words" register
  produces "tempo climbs toward the peak". After "make it more chill", four
  songs in a row read "the comedown after that run".

## Decisions

1. **The curator returns only songs that fit.** The curation prompt says to
   pick only tracks that truly fit the brief (genre, era, mood, and any hard
   constraint such as no vocals or clean), and to return fewer than asked
   rather than use a track that contradicts it. The requested count becomes a
   ceiling, not a quota. A genre or era named in the brief is a hard
   constraint; mood words never stand in for it. Each pool line shows Apple's
   genre label, which is the evidence for a named genre: a track labelled
   otherwise fits only when the song itself is widely known as that genre.
   Added after the live rerun, where an own-music "soft jazz" mix held
   Alternative and Afrobeats songs.
2. **A shortfall is filled from outside the library, then honestly.** When the
   curated picks fall short of `targetCount`, the listener allows outside music
   (`allowOutside` is not false), and the Apple fill is wired (`NEVER_REFUSE`
   on), the shortfall is proposed and verified exactly like the existing blend
   (`blendProposals`: one round, Apple search verification, within the turn's
   fill budget), and spread through the mix with `interleaveBlend`. This applies
   to personal and corpus listeners alike; the corpus blend's fixed share stays
   as a minimum.
   - The tool result says how many songs came from outside the library, so the
     reply can say so.
   - If proposals fail or are disallowed, the mix is shorter and the tool result
     tells the model to say plainly why ("your library has little jazz").
     A mix of at least one song is still a mix (never refuse).
   - Proposals go through the same fit rule: a proposal for "no vocals" must be
     an instrumental.
3. **Named artists in an edit are a scope.** A swap or extend whose intent names
   artists (`namedArtists`) draws its replacements only from those artists'
   songs, as an artist-only mix does (`onlyArtistKey` pool, credited keys so
   features count, catalogue fill for an artist with too few rows). None found
   leaves the original track and the tool result says so. "Swap in some
   Kendrick" therefore lands Kendrick or says it could not.
4. **A turn whose queue changed never fails silently.** If the turn errors
   after the queue was written, the server saves a short factual DJ message
   built from the change ("Swapped 3 songs.") and returns the turn as a
   success with the new queue. No queue change without a message.
5. **The reply describes only what is in the listing.** The persona prompt
   gains: never say an artist anchors, leads or features in the mix unless a
   song by them is in the updated listing; when the listing differs from the
   request, say how.
6. **Intros, interludes, skits and outros stay out** of every pool (title
   matches `intro`, `interlude`, `skit` or `outro` as a whole word, including
   "includes ... skit"), unless the listener names that song.
7. **Notes are one or two sentences that make the case for the song.** Each
   note says one concrete thing about that song (its sound, production, the
   feeling or theme of its lyric, the artist's delivery) and why it sits at that
   point in the mix. 12 to 28 words, sentence case, no em dashes. It never
   quotes lyrics (lyrics stance) and never names the track or artist. Banned:
   restating the request ("matches your vibe", "fits the mood", "great choice")
   and bare arc labels ("the peak hits", "the comedown"). The cap rises from
   140 to 200 characters. A note that repeats one already in the queue
   (case- and punctuation-insensitive) is dropped to no note, never shown
   twice. The proposal path uses the same rule. This reverses the "two to six
   words" register.
   - A note that is the model's own aside ("Wait, remove if era wrong", live
     2026-11-10) is never shown, and the song goes with it: the model doubted
     it (`notes.ts` `isScratchNote`, on curated picks and proposals alike).

8. **A named genre is checked by how a song sounds** (founder, 2026-11-09:
   "it doesn't have to be a hard genre filter but we need to be sure that the
   songs added sound like jazz"). After the prompt rule above, the live
   "soft jazz" mix still held 2 jazz songs among 14 soul and indie ones.
   - The intent gains `genres` (up to 3), set only when the brief names a
     genre ("soft jazz" → jazz; "90s r&b slow jams" → r&b; "afrobeats and
     amapiano" → both). Moods, eras and activities are not genres.
   - Every song headed for the queue, curated or proposed, whose Apple genre
     label matches a named genre passes without a check. Matching is by
     normalised words plus a small alias table (r&b ↔ R&B/Soul; hip hop ↔
     Hip-Hop/Rap, Rap, Hip-Hop; afrobeats ↔ Afrobeats, African, Afro-Pop).
   - Every other song goes to one sound check: a fast model call
     (`TITLE_MODEL`, already used for mix titles) asked, per song, whether a
     listener who asked for that genre would hear it as that genre, judged
     on instrumentation, harmony, rhythm and vocal style. "Influenced by" or
     "adjacent to" does not pass. One call for the curated songs and at most
     one for unmatched proposals.
   - Songs that fail leave the mix. The shortfall is filled as in decision 2,
     and those proposals pass the same check, or the mix is shorter and the
     DJ says why.
   - With a genre named, the shortfall verifies spares (as many again as it
     needs, at most `PROPOSE_EXTRA`, inside the search budget), so a proposal
     that fails the check is replaced from the same round. Live 2026-11-10,
     "90s r&b slow jams" came back 5 songs on one run and 15 on the next.
     The notice counts only places left empty.
   - If the check itself fails (error or timeout), only label-matched songs
     stay: the mix may be shorter, but never holds an unchecked song.
   - The same check applies to swaps and extends whose intent names a genre.
     Artist-only mixes skip it unless a genre is also named.
   - The check's model calls count toward the turn's subrequest margin.

9. **A genre mix stays inside the app's 120 s** (2026-11-10). A local
   "90s r&b" turn took 87 s: 23 s curating, then 30 s proposing, then 12 s
   verifying one Apple search at a time. Production runs reached 130 s.
   - A personal listener's genre brief asks for its outside songs while the
     library curation runs (the whole mix's worth, since the shortfall is
     not known yet), then verifies only what the curation left unfilled,
     dropping songs it already chose. If that call comes back thin and the
     turn is under `ROUND_TWO_CUTOFF_MS`, one round runs as before.
   - Apple verification runs `VERIFY_CONCURRENCY` (4) searches at a time,
     in proposal order, never more than could still verify.
   - With proposals coming (the corpus blend or the early shortfall), a
     curation that fails (cut off, unreadable, the call failing) is no
     picks: the proposals fill the mix, and its error stands only when
     nothing lands. The turn log marks it `curationFailed`.
   - The turn log gains `timing`: each model call's start and duration.
   - Measured locally after: 49 to 77 s for the same prompts.

## Out of scope

- Client changes. Notes already open on tap in a wrapping band; the web rail
  shows them on hover and focus. Longer text needs no layout change.
- A paid Workers plan or a larger fill budget.

## Tests

- Server, curation (structural, never exact tracks): the system prompt carries
  the fit rule and the new note rule; picks fewer than asked are accepted;
  duplicate notes are dropped against the queue; the 200-character cap.
- Pool: titles with intro, interlude, skit or outro are excluded unless named.
- Loop: a personal generate that curates short runs a proposal round for the
  shortfall and interleaves it; `allowOutside: false` skips it and the result
  says why; a swap naming an artist draws only that artist; a turn that errors
  after a queue write returns success with a fallback message.
- Live check after deploy: rerun the pressure-test prompts.

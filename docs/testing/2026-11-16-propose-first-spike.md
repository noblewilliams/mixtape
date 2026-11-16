# Propose-first spike (Step 0)

Run 2026-11-16 09:01 UTC by `server/scripts/propose-first-spike.ts`. Read-only against production: SELECTs only, no inserts, no `verifyProposals`.

## Gate 0

| Gate | Threshold | Measured | Result |
|---|---|---|---|
| Apple verify rate, mainstream briefs | ≥ 70% | 88.7% (290/327) | pass |
| ReccoBeats energy on verified proposals | ≥ 60% | 69.0% (138/200) | pass |
| Model energy estimate MAE vs ReccoBeats | ≤ 0.15 | 0.134 (n=138) | pass |

## Free feature coverage

Catalogue sample: 500 ISRCs (target 500); verified-proposal sample: 200 ISRCs (target 200). ReccoBeats first (title search, artist + duration gate, as enrichment does), Deezer `/track/isrc:<ISRC>` only for ReccoBeats misses and errors.

| Set | n | ReccoBeats energy | Deezer bpm>0 (of RB misses) | Deezer bpm=0 | Deezer error body | Either |
|---|---|---|---|---|---|---|
| chart | 125 | 44.0% | 20.0% (14/70) | 54 | 2 | 55.2% |
| library | 125 | 47.2% | 28.8% (19/66) | 41 | 6 | 62.4% |
| non_english | 125 | 44.0% | 24.3% (17/70) | 52 | 1 | 57.6% |
| pre1980 | 125 | 64.8% | 70.5% (31/44) | 8 | 5 | 89.6% |
| all catalogue | 500 | 50.0% | 32.4% (81/250) | 155 | 14 | 66.2% |
| proposal | 200 | 69.0% | 66.1% (41/62) | 19 | 2 | 89.5% |

- ReccoBeats: 700 lookups, p50 1571 ms, p95 3523 ms (a lookup is a search plus a features fetch on a match). 429s: 0. Other errors: 3 (HTTP 400). Hits without an energy value: 0.
- Deezer: 312 lookups, p50 294 ms, p95 494 ms. bpm>0 122, bpm=0 174 (58.8% of found tracks), error body 16 (`DataException:800` ×16), HTTP/fetch errors 0.

## Proposal quality (library listeners)

- Founder account: 4762 songs, storefront `ng`, 10 top artists sent.
- Exportify test account: 830 songs (all `in_library = false`, Spotify export), storefront `ng` (no profile storefront; the loop's `ng` fallback), 10 top artists sent (counted over every row, since `topLibraryArtists` counts in-library rows only and would send none).

Mainstream briefs: 88.7% verified (290/327). Genre/era/constraint briefs: 71.1% (204/287). All: 80.5%.

Outcomes across all proposals: verified 494, no_match 85, no_results 34, duplicate 1. `no_match` means Apple returned songs but none passed `pickHit` (title key, credited artist, no unasked version word); `no_results` means the search came back empty.

Apple search failures on the first pass (three briefs at once, up to 12 searches in flight): 44. Retried one at a time: 8 verified, 36 did not, 0 still errored. Apple answers an empty search with a 200 that has no `results.songs`, which the catalog client throws as `response:200`; those are counted as `no_results` (production `verifyProposals` counts them as misses too, so the verify rate is the same either way). Songs verified on the retry are counted as verified but were not in the ReccoBeats proposal sample (drawn before the retry).

Of 494 verified: already owned by that listener 82 (16.6%); Apple title differs from the proposed title 58; of those, carrying a version marker the proposal lacked 11.

| Account | Brief | Main | Proposed | Verified | Rate | Owned | Title differs | In tok | Out tok | Calls | Est. given |
|---|---|---|---|---|---|---|---|---|---|---|---|
| founder | upbeat pop for a sunday morning clean-up | y | 21 | 21 | 100.0% | 6 | 0 | 1375 | 1933 | 1 | 21 |
| founder | 2000s hip hop party bangers | y | 19 | 19 | 100.0% | 5 | 2 | 1369 | 3381 | 1 | 19 |
| founder | afrobeats for a friday night out | y | 21 | 15 | 71.4% | 6 | 3 | 1359 | 1638 | 1 | 21 |
| founder | feel-good throwbacks for a road trip | y | 22 | 22 | 100.0% | 3 | 3 | 1365 | 3928 | 1 | 22 |
| founder | workout mix, high energy rap and pop | y | 9 | 9 | 100.0% | 8 | 2 | 1373 | 779 | 1 | 9 |
| founder | Frank Ocean and Daniel Caesar | y | 21 | 17 | 81.0% | 5 | 3 | 1396 | 1781 | 1 | 21 |
| founder | classic rock anthems | y | 22 | 21 | 95.5% | 1 | 0 | 1356 | 4040 | 1 | 22 |
| founder | chill r&b for a late night drive | y | 22 | 14 | 63.6% | 4 | 6 | 1362 | 1745 | 1 | 22 |
| founder | 90s r&b slow jams for a dinner date |  | 21 | 19 | 90.5% | 0 | 0 | 1380 | 1661 | 1 | 20 |
| founder | rainy sunday reading, soft jazz |  | 20 | 12 | 60.0% | 1 | 0 | 1367 | 1755 | 1 | 20 |
| founder | focus music, no vocals |  | 21 | 15 | 71.4% | 1 | 2 | 1361 | 2485 | 1 | 21 |
| founder | 80s synth-pop deep cuts |  | 22 | 18 | 81.8% | 0 | 2 | 1381 | 3800 | 1 | 22 |
| founder | old-school highlife classics |  | 21 | 8 | 38.1% | 0 | 1 | 1367 | 2600 | 1 | 21 |
| founder | bossa nova for a slow dinner |  | 21 | 17 | 81.0% | 0 | 3 | 1366 | 1677 | 1 | 21 |
| founder | ambient electronic for coding late at night |  | 20 | 12 | 60.0% | 3 | 0 | 1369 | 1675 | 1 | 20 |
| exportify | upbeat pop for a sunday morning clean-up | y | 21 | 21 | 100.0% | 10 | 3 | 1383 | 1715 | 1 | 21 |
| exportify | 2000s hip hop party bangers | y | 20 | 18 | 90.0% | 1 | 2 | 1377 | 3189 | 1 | 20 |
| exportify | afrobeats for a friday night out | y | 22 | 20 | 90.9% | 0 | 4 | 1367 | 3127 | 1 | 22 |
| exportify | feel-good throwbacks for a road trip | y | 21 | 21 | 100.0% | 4 | 1 | 1373 | 1752 | 1 | 21 |
| exportify | workout mix, high energy rap and pop | y | 22 | 20 | 90.9% | 7 | 2 | 1381 | 3200 | 1 | 22 |
| exportify | Frank Ocean and Daniel Caesar | y | 22 | 16 | 72.7% | 10 | 3 | 1404 | 1813 | 1 | 22 |
| exportify | classic rock anthems | y | 22 | 21 | 95.5% | 0 | 0 | 1364 | 1637 | 1 | 22 |
| exportify | chill r&b for a late night drive | y | 20 | 15 | 75.0% | 7 | 4 | 1370 | 1612 | 1 | 20 |
| exportify | 90s r&b slow jams for a dinner date |  | 11 | 11 | 100.0% | 0 | 0 | 1388 | 1062 | 1 | 11 |
| exportify | rainy sunday reading, soft jazz |  | 22 | 15 | 68.2% | 0 | 1 | 1375 | 1984 | 1 | 22 |
| exportify | focus music, no vocals |  | 20 | 18 | 90.0% | 0 | 3 | 1369 | 3431 | 1 | 20 |
| exportify | 80s synth-pop deep cuts |  | 22 | 21 | 95.5% | 0 | 3 | 1389 | 2247 | 1 | 22 |
| exportify | old-school highlife classics |  | 22 | 3 | 13.6% | 0 | 0 | 1375 | 1853 | 1 | 22 |
| exportify | bossa nova for a slow dinner |  | 22 | 20 | 90.9% | 0 | 3 | 1374 | 1752 | 1 | 22 |
| exportify | ambient electronic for coding late at night |  | 22 | 15 | 68.2% | 0 | 2 | 1377 | 1740 | 1 | 22 |

Tokens: 30 Sonnet calls (`claude-sonnet-5`, effort medium), input 41212 total (mean 1374, max 1404), output 66992 total (mean 2233, max 4040). Cache reads: 0. max_tokens stops: 0. Call latency p50 22072 ms, p95 39592 ms.

### Verified picks whose Apple title differs (judge by eye)

| Account | Brief | Proposed | Apple hit | Marker |
|---|---|---|---|---|
| founder | 2000s hip hop party bangers | Crazy in Love by Beyoncé | Crazy in Love (feat. JAŸ-Z) by Beyoncé |  |
| founder | 2000s hip hop party bangers | Gold Digger by Kanye West | Gold Digger (feat. Jamie Foxx) by Kanye West |  |
| founder | afrobeats for a friday night out | Essence by Wizkid | Essence (feat. Tems) by Wizkid |  |
| founder | afrobeats for a friday night out | Love Nwantiti by CKay | love nwantiti (ah ah ah) by CKay |  |
| founder | afrobeats for a friday night out | Buga by Kizz Daniel | Buga (Lo Lo Lo) by Kizz Daniel & Tekno |  |
| founder | feel-good throwbacks for a road trip | Good Life by Kanye West | Good Life (feat. T-Pain) by Kanye West |  |
| founder | feel-good throwbacks for a road trip | Uptown Funk by Mark Ronson | Uptown Funk (feat. Bruno Mars) by Mark Ronson |  |
| founder | feel-good throwbacks for a road trip | Crazy In Love by Beyoncé | Crazy in Love (feat. JAŸ-Z) by Beyoncé |  |
| founder | workout mix, high energy rap and pop | Till I Collapse by Eminem | 'Till I Collapse (feat. Nate Dogg) by Eminem |  |
| founder | workout mix, high energy rap and pop | Lose Yourself by Eminem | Lose Yourself (From "8 Mile") by Eminem |  |
| founder | Frank Ocean and Daniel Caesar | Best Part by Daniel Caesar | Best Part (feat. H.E.R.) by Daniel Caesar |  |
| founder | Frank Ocean and Daniel Caesar | Get You by Daniel Caesar | Get You (feat. Kali Uchis) by Daniel Caesar |  |
| founder | Frank Ocean and Daniel Caesar | Super Rich Kids by Frank Ocean | Super Rich Kids (feat. Earl Sweatshirt) by Frank Ocean |  |
| founder | chill r&b for a late night drive | Best Part by Daniel Caesar | Best Part (feat. H.E.R.) by Daniel Caesar |  |
| founder | chill r&b for a late night drive | Come Through and Chill by Miguel | Come Through and Chill (feat. J. Cole & Salaam Remi) by Miguel |  |
| founder | chill r&b for a late night drive | Pretty Little Fears by 6LACK | Pretty Little Fears (feat. J. Cole) by 6LACK |  |
| founder | chill r&b for a late night drive | New Flame by Chris Brown | New Flame (feat. Usher & Rick Ross) by Chris Brown |  |
| founder | chill r&b for a late night drive | Nights Like This by Kehlani | Nights Like This (feat. Ty Dolla $ign) by Kehlani |  |
| founder | chill r&b for a late night drive | Pink Matter by Frank Ocean | Pink Matter (feat. André 3000) by Frank Ocean |  |
| founder | focus music, no vocals | Eclipse/Blue by Nosaj Thing | Eclipse / Blue (feat. Kazu Makino) by Nosaj Thing |  |
| founder | focus music, no vocals | Vex Oh by Kaytranada | Vex Oh (feat. GoldLink & Ari PenSmith) by KAYTRANADA & Eight9fly |  |
| founder | 80s synth-pop deep cuts | Baby Doll by Soft Cell | Baby Doll (Dub) by Soft Cell |  |
| founder | 80s synth-pop deep cuts | Party Fears Two by The Associates | Party Fears Two (2016 Remaster) by The Associates | yes |
| founder | old-school highlife classics | Taxi Driver by Bobby Benson | Taxi Driver (Version 2) by Bobby Benson | yes |
| founder | bossa nova for a slow dinner | Garota de Ipanema by João Gilberto | Garota De Ipanema (The Girl From Ipanema) by João Gilberto |  |
| founder | bossa nova for a slow dinner | Corcovado by João Gilberto | Corcovado (Quiet Nights of Quiet Stars) [feat. Astrud Gilberto & Antônio Carlos Jobim] [Mono] by Stan Getz & João Gilberto | yes |
| founder | bossa nova for a slow dinner | Só Danço Samba by João Gilberto | Só Danço Samba (feat. Antônio Carlos Jobim) by Stan Getz & João Gilberto |  |
| exportify | upbeat pop for a sunday morning clean-up | Uptown Funk by Mark Ronson | Uptown Funk (feat. Bruno Mars) by Mark Ronson |  |
| exportify | upbeat pop for a sunday morning clean-up | California Gurls by Katy Perry | California Gurls (feat. Snoop Dogg) by Katy Perry |  |
| exportify | upbeat pop for a sunday morning clean-up | Valerie by Mark Ronson | Valerie (Version Revisited) by Amy Winehouse & Mark Ronson | yes |
| exportify | 2000s hip hop party bangers | Yeah! by Usher | Yeah! (feat. Lil Jon & Ludacris) by USHER |  |
| exportify | 2000s hip hop party bangers | Crank That (Soulja Boy Tell'em) by Soulja Boy Tell'em | Crank That (Soulja Boy) by Soulja Boy Tell 'Em |  |
| exportify | afrobeats for a friday night out | Essence by Wizkid | Essence (feat. Tems) by Wizkid |  |
| exportify | afrobeats for a friday night out | Love Nwantiti by CKay | love nwantiti (ah ah ah) by CKay |  |
| exportify | afrobeats for a friday night out | Buga by Kizz Daniel | Buga (Lo Lo Lo) by Kizz Daniel & Tekno |  |
| exportify | afrobeats for a friday night out | Elon Musk by Shallipopi | Elon Musk (Mixed) by Shallipopi |  |
| exportify | feel-good throwbacks for a road trip | Uptown Funk by Mark Ronson | Uptown Funk (feat. Bruno Mars) by Mark Ronson |  |
| exportify | workout mix, high energy rap and pop | Till I Collapse by Eminem | 'Till I Collapse (feat. Nate Dogg) by Eminem |  |
| exportify | workout mix, high energy rap and pop | Lose Yourself by Eminem | Lose Yourself (From "8 Mile") by Eminem |  |
| exportify | Frank Ocean and Daniel Caesar | Best Part by Daniel Caesar | Best Part (feat. H.E.R.) by Daniel Caesar |  |
| exportify | Frank Ocean and Daniel Caesar | Get You by Daniel Caesar | Get You (feat. Kali Uchis) by Daniel Caesar |  |
| exportify | Frank Ocean and Daniel Caesar | Come Through and Chill by Miguel | Come Through and Chill (feat. J. Cole & Salaam Remi) by Miguel |  |
| exportify | chill r&b for a late night drive | Best Part by Daniel Caesar | Best Part (feat. H.E.R.) by Daniel Caesar |  |
| exportify | chill r&b for a late night drive | Love Galore by SZA | Love Galore (Alt Version) by SZA | yes |
| exportify | chill r&b for a late night drive | Pink Matter by Frank Ocean | Pink Matter (feat. André 3000) by Frank Ocean |  |
| exportify | chill r&b for a late night drive | Moon River (Frank Ocean cover) by Frank Ocean | Moon River by Frank Ocean |  |
| exportify | rainy sunday reading, soft jazz | Corcovado by Stan Getz | Corcovado (Quiet Nights of Quiet Stars) by Stan Getz, Astrud Gilberto, Antônio Carlos Jobim & João Gilberto |  |
| exportify | focus music, no vocals | Form by Firelight by Jon Hopkins | Form By Firelight (with Raphaelle Standell [Asleep Version]) by Jon Hopkins | yes |
| exportify | focus music, no vocals | Eclipse/Blue by Nosaj Thing | Eclipse / Blue (feat. Kazu Makino) by Nosaj Thing |  |
| exportify | focus music, no vocals | Feather by Nujabes | Feather (feat. Cise Star & Akin) by Nujabes |  |
| exportify | 80s synth-pop deep cuts | Party Fears Two by The Associates | Party Fears Two (2016 Remaster) by The Associates | yes |
| exportify | 80s synth-pop deep cuts | Talk Talk by Talk Talk | Talk Talk (1997 - Remaster) by Talk Talk | yes |
| exportify | 80s synth-pop deep cuts | Love Action by The Human League | Love Action (I Believe In Love) [Edit] by The Human League | yes |
| exportify | bossa nova for a slow dinner | Garota de Ipanema by João Gilberto | Garota De Ipanema (The Girl From Ipanema) by João Gilberto |  |
| exportify | bossa nova for a slow dinner | Corcovado by João Gilberto | Corcovado (Quiet Nights of Quiet Stars) [feat. Astrud Gilberto & Antônio Carlos Jobim] [Mono] by Stan Getz & João Gilberto | yes |
| exportify | bossa nova for a slow dinner | Vou Deitar e Rolar by Elis Regina | Vou Deitar e Rolar (Quaquaraquaqua) by Elis Regina |  |
| exportify | ambient electronic for coding late at night | Divinity by Porter Robinson | Divinity (feat. Amy Millan) by Porter Robinson |  |
| exportify | ambient electronic for coding late at night | Immunity by Jon Hopkins | Immunity (Remaster 2023) by Jon Hopkins | yes |

### Unverified proposals (sample, judge by eye)

| Account | Brief | Proposed | Outcome |
|---|---|---|---|
| founder | afrobeats for a friday night out | Soco by Wizkid | no_match |
| founder | afrobeats for a friday night out | Loose Up by Kizz Daniel | no_match |
| founder | afrobeats for a friday night out | Kilometre by Olamide | no_match |
| founder | afrobeats for a friday night out | Nzaza by Olamide | no_match |
| founder | afrobeats for a friday night out | Rara by Rema | no_match |
| founder | afrobeats for a friday night out | Overdem by Skepta | no_results |
| founder | Frank Ocean and Daniel Caesar | Still by Daniel Caesar | no_match |
| founder | Frank Ocean and Daniel Caesar | Hallucinate by Daniel Caesar | no_results |
| founder | Frank Ocean and Daniel Caesar | Call Me Crazy by Daniel Caesar | no_match |
| founder | Frank Ocean and Daniel Caesar | Save Your Love by Daniel Caesar | no_match |
| founder | classic rock anthems | Layla by Derek and the Dominos | no_match |
| founder | chill r&b for a late night drive | Nights by Kendrick Lamar | no_match |
| founder | chill r&b for a late night drive | The Light by PARTYNEXTDOOR | no_match |
| founder | chill r&b for a late night drive | Up Late by Tyler, The Creator | no_match |
| founder | chill r&b for a late night drive | Deja Vu by Giveon | no_match |
| founder | chill r&b for a late night drive | Case Study 01 by 6LACK | no_match |
| founder | chill r&b for a late night drive | Body by Kehlani | no_match |
| founder | chill r&b for a late night drive | Still Fly by Daniel Caesar | no_match |
| founder | chill r&b for a late night drive | Bedroom Walls by Mila J | no_match |
| founder | 90s r&b slow jams for a dinner date | My Boo by Ghost Town DJ's | no_match |
| founder | 90s r&b slow jams for a dinner date | Forever More by Tamia | no_match |
| founder | rainy sunday reading, soft jazz | Trouble Is a Man by Melody Gardot | no_match |
| founder | rainy sunday reading, soft jazz | Girl Talk by Stan Getz | no_match |
| founder | rainy sunday reading, soft jazz | The Nearness of You by John Coltrane | no_match |
| founder | rainy sunday reading, soft jazz | My One and Only Love by Jose James | no_match |
| founder | rainy sunday reading, soft jazz | The Way You Look Tonight by Keith Jarrett | no_match |
| founder | rainy sunday reading, soft jazz | Skylark by Esperanza Spalding | no_results |
| founder | rainy sunday reading, soft jazz | Loverman by Gregory Porter | no_results |
| founder | rainy sunday reading, soft jazz | Moon River by Diana Krall | no_match |
| founder | focus music, no vocals | Twurkle by Knxwledge | no_results |
| founder | focus music, no vocals | Camera Flowers by Mndsgn | no_results |
| founder | focus music, no vocals | Lovely by Jinsang | no_match |
| founder | focus music, no vocals | Petrichor by L'Indécis | no_results |
| founder | focus music, no vocals | Soon It Will Be Cold Enough by Emancipator | no_match |
| founder | focus music, no vocals | Wavy by Kiefer | no_match |
| founder | 80s synth-pop deep cuts | Let Me Go by Heaven 17 | no_match |
| founder | 80s synth-pop deep cuts | Metro by Berlin | no_match |
| founder | 80s synth-pop deep cuts | Told You So by Depeche Mode | no_match |
| founder | 80s synth-pop deep cuts | Souvenir by OMD | no_match |
| founder | old-school highlife classics | Sawale by Rex Lawson | no_match |
| founder | old-school highlife classics | Osondi Owendi by Osita Osadebe | no_match |
| founder | old-school highlife classics | Egwu Ndi Beke by Oriental Brothers Band | no_match |
| founder | old-school highlife classics | Baby Ngozi by Oriental Brothers Band | no_match |
| founder | old-school highlife classics | Identity by Oliver De Coque | no_match |
| founder | old-school highlife classics | Sika Ye Mogya by Pat Thomas | no_match |
| founder | old-school highlife classics | Funky Highlife by C.K. Mann | no_match |
| founder | old-school highlife classics | Gyae Su by Alex Konadu | no_results |
| founder | old-school highlife classics | Ebi Te Yie by African Brothers Band | no_match |
| founder | old-school highlife classics | Yesu Ye Odo by Nat Brew | no_results |
| founder | old-school highlife classics | Yaa Amponsah by Jerry Hansen and The Ramblers Dance Band | no_results |
| founder | old-school highlife classics | Iyo Adaka by Amakye Dede | no_results |
| founder | old-school highlife classics | Ndi Ara by Super Combo | no_match |
| founder | bossa nova for a slow dinner | Dindi by João Gilberto | no_match |
| founder | bossa nova for a slow dinner | O Barquinho by Astrud Gilberto | no_match |
| founder | bossa nova for a slow dinner | Aguas De Março by Tom Jobim | no_match |
| founder | bossa nova for a slow dinner | Fotografia by Vinicius de Moraes | no_match |
| founder | ambient electronic for coding late at night | Emergence by Jon Hopkins | no_results |
| founder | ambient electronic for coding late at night | Saspotch by Nils Frahm | no_results |
| founder | ambient electronic for coding late at night | Atlas by Real Estate | no_match |
| founder | ambient electronic for coding late at night | Spotlight by Four Tet | no_match |
| | | … 59 more | |

## Model estimate error

Verified proposals with both a model estimate and a ReccoBeats measurement: energy n=138, valence n=138.

| Feature | MAE | Within 0.15 | Within 0.25 | Pearson r | Baseline MAE (predict the sample mean) |
|---|---|---|---|---|---|
| energy | 0.134 | 63.8% | 84.8% | 0.74 | 0.199 |
| valence | 0.182 | 52.2% | 69.6% | 0.60 | 0.211 |


## Reading (written by hand after the run)

**Gate 0 verdict: pass on all three gates.** Mainstream verify rate is 88.7%
(founder 138/157, Exportify 152/170), ReccoBeats measured energy for 69.0% of
verified proposals, and the model's energy estimate is off by 0.134 on
average (n=138). Under Gate 0's own rule, S9 may sequence with estimates as
well as measured energy. Valence is weaker (MAE 0.182, r 0.60) and was not
gated. Use it as a soft signal only.

What the numbers do and don't say:

- **Estimate margin is thin.** 0.134 is just under 0.15. Only 63.8% of songs
  land within 0.15, the model reads slightly low (mean signed error -0.065),
  and 10 of 138 are off by more than 0.3. Some of those look like ReccoBeats
  matching a different recording rather than a bad estimate (for example
  Boyz II Men "Let's Stay Together" measured 0.74 against an estimate of
  0.30). The model gave Kendrick Lamar "HUMBLE." an energy of 0, which is a
  real miss. The constant-mean baseline is 0.199, so the estimates do carry
  signal (r 0.74). Re-measure after S3 ships, since the estimate prompt there
  may be worded differently.
- **Genre/era/constraint briefs verify at 71.1%** and drop sharply on
  regional or older catalogues: old-school highlife 8/21 and 3/22. Most of
  those misses are songs Apple's `ng` storefront doesn't return by title
  search (`no_results`), or a credit Apple spells differently (`no_match`,
  for example "Oriental Brothers Band" vs "Oriental Brothers International
  Band"). Some may also be invented songs. Soft jazz (60%, 68%), focus (62%,
  90%) and ambient (60%, 68%) sit around two-thirds.
- **Wrong versions are rare and mostly harmless.** 58 verified picks have an
  Apple title that differs from the proposed one. Most only add a "feat."
  credit. 11 carry a version marker the proposal lacked. Of those, the
  likely real wrong picks are "Baby Doll (Dub)" (Soft Cell), "Love Galore
  (Alt Version)" (SZA), "Valerie (Version Revisited)" (credited to Amy
  Winehouse & Mark Ronson), "Form By Firelight ... [Asleep Version]" (Jon
  Hopkins), "Elon Musk (Mixed)" (Shallipopi) and "Taxi Driver (Version 2)"
  (Bobby Benson). The rest are remasters, edits or mono masters. That is
  about 6 of 494 (1.2%). `pickHit`'s version-word list doesn't catch "Dub",
  "Alt Version", "Version Revisited" or "Asleep Version".
- **Owned share is 16.6% overall** (founder 43/239, Exportify 39/255 among
  verified). It is concentrated in mainstream briefs that overlap the
  listener's top artists (Exportify "Frank Ocean and Daniel Caesar" 10/16,
  "upbeat pop" 10/21) and is about zero on genre briefs. Step 2's "tell
  proposals what the listener owns" was not tested here. The prompt sent no
  owned list.
- **Free coverage of the catalogue is lower than on proposals.** ReccoBeats
  matched 50% of the 500 catalogue ISRCs (chart 44%, library 47%,
  non-English 44%, pre-1980 65%). Deezer by ISRC recovered 32% of the
  ReccoBeats misses, but 58.8% of the tracks Deezer found had `bpm: 0`.
  With both, 66% of the catalogue sample gets energy or tempo, against
  89.5% of verified proposals. Proposals are mostly well-known recordings,
  which is what both providers cover best. Deezer's not-found body is
  `{"error":{"type":"DataException","message":"no data","code":800}}`.
- **Rate limits:** no ReccoBeats 429s at one track per second (700 lookups,
  about 22 minutes, p50 1.6 s per lookup including the features fetch).
  This says nothing about the per-turn burst S4 plans (concurrency 4 inside
  6 s).

## Method notes and deviations

- **Verification is a read-only reimplementation.** For each proposal: one
  Apple catalogue search of `title artist` (limit 5, the account's
  storefront), then `pickHit` and the album-glue check, the same as
  `verifyProposals` but with no `addCatalogueSongs` insert. The first pass
  ran three briefs at once, so up to 12 searches were in flight. Its 44
  failures were retried one at a time. Every one of them was Apple's empty
  search: a 200 with no `results.songs`, which the catalog client throws as
  `response:200`. Those count as `no_results`. Production also counts them
  as misses, so the rate is unaffected. There was no Apple rate limiting.
  The 8 songs that verified on the retry were not in the ReccoBeats sample.
- **Estimates come from a spike-only prompt variant.** A wrapping LLM client
  replaced the output block of `PROPOSE_SYSTEM_PROMPT_PERSONAL` with one
  that also asks for `energy` and `valence`. `proposeSongs` itself ran
  unchanged. Estimates were joined back by title key plus artist key. The
  token counts include the extra fields, so output tokens run a little
  above what production's prompt would use today.
- **The briefs are a reconstruction.** The 2026-11-09 pressure test spec
  quotes only a few of its prompts ("90s r&b slow jams for a dinner date",
  "rainy sunday reading, soft jazz", "focus music, no vocals", "Frank Ocean
  and Daniel Caesar"). The other 11 are new: 8 mainstream and 7
  genre/era/constraint briefs in total. Intents were written by hand
  (targetCount 15, so 22 proposals asked per call), not produced by the
  DJ's intent tool. Any named artists were sent as seeds. Saved artist
  seeds (`user_artist_seeds`) and session context were not sent.
- **Exportify account handling.** It was identified as the Spotify-export
  user with 830 songs, matching the 2026-10-03 drain notes. All its rows
  are `in_library = false`, so production's `topLibraryArtists` would send
  no top artists. The spike counted artists over all its rows instead. It
  has no profile storefront, so `ng` was used, the loop's fallback.
  "Owned" for both accounts means any `user_tracks` row, matched by ISRC or
  by folded title plus artist.
- **The catalogue sample** has 4 disjoint strata of 125 each, taken in a
  fixed order: pre-1980 release year, non-ASCII title, held by some
  listener, then held by no listener (charts, editorial playlists and
  earlier verified proposals). The heuristics are rough. "Non-English" is
  non-ASCII titles only, so it misses most Nigerian and English-titled
  non-English songs.
- **Not measured:** the curation pool's token cost before and after
  (spec Step 0's third bullet). Only the proposal call's tokens were
  recorded: 30 calls, mean 1,374 input and 2,233 output. Also not measured:
  ReccoBeats under burst concurrency, Apple's rate ceiling at
  `VERIFY_CONCURRENCY` above 4, and storefronts other than `ng`.
- **Rerun** from `server/` with `npx tsx scripts/propose-first-spike.ts`.
  `--reuse <raw.json>` rebuilds this report from saved results without
  spending again. Rebuilding replaces this hand-written section.

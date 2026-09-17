# Exportify parser contract

`sample.csv` is synthetic. `expected.json` records its independently specified
snapshot for UTC before collection review. Web and Dart must produce this same
result: one unique recording, three ordered entries, one unresolved entry,
and no inferred library membership or listening history. The CSV content hash
is for reviewed import identity, never a Spotify playlist identifier.

`headers.json` lists the relevant upstream labels from Exportify translations,
verified 2026-09-08 against https://github.com/watsonbox/exportify. Production
copies in both clients must match this fixture. Optional columns are tolerated;
ISRC and artwork are deliberately not promoted to trusted catalog metadata.

# Exportify parser contract

`sample.csv` is synthetic. `expected.json` records its independently specified
snapshot for UTC before collection review. Web and Dart must produce this same
result: one unique recording, three ordered entries, one unresolved entry,
and no inferred library membership or listening history. The CSV content hash
is for reviewed import identity, never a Spotify playlist identifier.

`headers.json` lists the relevant upstream labels from Exportify translations,
verified 2026-09-08 against https://github.com/watsonbox/exportify. Production
copies in both clients must match this fixture. Optional columns are tolerated.
ISRC is carried as an optional `isrc` on each track: trimmed, hyphens and
spaces removed, uppercased, kept only when it matches
`^[A-Z]{2}[A-Z0-9]{3}[0-9]{7}$`, otherwise omitted. The first well-formed value
per recording wins (files in path order, rows in file order); a repeated ISRC
column is ignored rather than failing the file. Only the untranslated `ISRC`
label is mapped. Artwork is deliberately not promoted to catalog metadata.

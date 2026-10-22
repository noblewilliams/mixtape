// Page limits for the catalogue seed (routes/enrich-seed.ts), in their own
// module so scripts/seed-catalogue.ts can read them without loading the
// route. The chart page is below the catalogue client's own 200 cap: parsing
// 200 songs and inserting them can exceed the free plan's per-request CPU,
// and a killed request would read as an Apple limit to the script.
export const MAX_CHART_PAGE = 100
export const MAX_PLAYLIST_PAGE = 100
export const MAX_PLAYLIST_SEARCH = 25

// Approved tape colours; persisted once on creation and shared by both clients.
export const TAPE_CASE_COLORS = [
  '#d88c9a', // Rose
  '#b84755', // Cherry
  '#a32440', // Crimson
  '#762d44', // Wine
  '#e77b6d', // Coral
  '#e8b1b5', // Blush
  '#e7a269', // Apricot
  '#e98135', // Tangerine
  '#bc5734', // Rust
  '#a9624f', // Terracotta
  '#efbd91', // Peach
  '#b97948', // Copper
  '#ead687', // Butter
  '#e6b52e', // Marigold
  '#bc8c29', // Ochre
  '#a89031', // Mustard
  '#c8b080', // Sand
  '#ddcba3', // Champagne
  '#aaba83', // Pistachio
  '#93b53e', // Lime
  '#7f883c', // Olive
  '#627445', // Moss
  '#8aab91', // Sage
  '#33654c', // Forest
  '#88c9b3', // Mint
  '#5dab9c', // Seafoam
  '#268b83', // Teal
  '#27626d', // Petrol
  '#70bfcb', // Aqua
  '#accdd7', // Ice
  '#87b5df', // Sky
  '#477fbd', // Blue
  '#3257ae', // Cobalt
  '#293e6c', // Navy
  '#617f9c', // Denim
  '#536674', // Slate
  '#b5a0d6', // Lilac
  '#9564b1', // Violet
  '#704674', // Plum
  '#c77fbd', // Orchid
  '#d786ae', // Pink
  '#c9bddb', // Lavender
  '#ddd5c2', // Cream
  '#a6a398', // Stone
  '#948373', // Taupe
  '#715547', // Cocoa
  '#49464e', // Graphite
  '#282a35', // Ink
] as const

// SQL defaults cover every insert path, including scripts and older API versions.
export const TAPE_CASE_COLOR_DEFAULT_SQL =
  `(ARRAY[${TAPE_CASE_COLORS.map(color => `'${color}'`).join(', ')}])[floor(random() * ${TAPE_CASE_COLORS.length})::int + 1]`

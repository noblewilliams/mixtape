#!/usr/bin/env node
// Link-preview cards for shared mixes with no artwork: the cassette alone on its tape
// colour (approved board L3), 600x600 PNG, one per colour plus the default case.
// Crawlers don't render SVG for og:image, so these are committed rasters under web/public/og/.
// Run with sharp available to Node, or SHARP_MODULE_PATH=/absolute/path/to/sharp.
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require(process.env.SHARP_MODULE_PATH || 'sharp');

const root = path.resolve(__dirname, '..');
const target = path.join(root, 'web/public/og');
const SIZE = 600;
const DEFAULT_CASE = '#3f4851';

// color-mix(in srgb, a p%, b)
function mix(a, b, p) {
  const channel = (hex, i) => parseInt(hex.slice(1 + i * 2, 3 + i * 2), 16);
  return '#' + [0, 1, 2].map(i => Math.round(channel(a, i) * p + channel(b, i) * (1 - p)).toString(16).padStart(2, '0')).join('');
}

function card(color, tape) {
  const inner = tape.replace(/^[\s\S]*?<svg[^>]*>/, '').replace(/<\/svg>\s*$/, '').replace(DEFAULT_CASE, color);
  const width = SIZE * 0.6;
  const height = width * 128 / 200;
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${SIZE}" height="${SIZE}" viewBox="0 0 ${SIZE} ${SIZE}">
  <defs>
    <radialGradient id="bg" cx="50%" cy="42%" r="71%">
      <stop offset="0" stop-color="${mix(color, '#ffffff', 0.88)}"/>
      <stop offset="1" stop-color="${mix(color, '#000000', 0.7)}"/>
    </radialGradient>
    <filter id="shadow" x="-20%" y="-20%" width="140%" height="160%">
      <feGaussianBlur in="SourceAlpha" stdDeviation="16"/>
      <feOffset dy="24" result="blur"/>
      <feComponentTransfer><feFuncA type="linear" slope="0.3"/></feComponentTransfer>
      <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <rect width="${SIZE}" height="${SIZE}" fill="url(#bg)"/>
  <g filter="url(#shadow)" transform="rotate(-4 ${SIZE / 2} ${SIZE / 2}) translate(${(SIZE - width) / 2} ${(SIZE - height) / 2}) scale(${width / 200})">${inner}</g>
</svg>`;
}

async function main() {
  const source = await fs.readFile(path.join(root, 'server/src/dj/tape-colors.ts'), 'utf8');
  const colors = [...source.matchAll(/'(#[0-9a-f]{6})'/g)].map(match => match[1]);
  const tape = await fs.readFile(path.join(root, 'web/public/tape.svg'), 'utf8');
  await fs.mkdir(target, { recursive: true });
  for (const color of [...new Set([...colors, DEFAULT_CASE])]) {
    const file = path.join(target, `tape-${color.slice(1)}.png`);
    await sharp(Buffer.from(card(color, tape))).flatten({ background: color }).png({ compressionLevel: 9, palette: true }).toFile(file);
    const metadata = await sharp(file).metadata();
    if (metadata.width !== SIZE || metadata.height !== SIZE) throw new Error(`Invalid card: ${file}`);
  }
  console.log(`Wrote ${colors.length + 1} cards to web/public/og/`);
}

main().catch(error => { console.error(error); process.exit(1); });

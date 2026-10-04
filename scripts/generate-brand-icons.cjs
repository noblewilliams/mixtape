#!/usr/bin/env node
// Run with sharp available to Node, or SHARP_MODULE_PATH=/absolute/path/to/sharp.
// Source SVGs are square and unmasked. The operating system supplies icon masks.
const fs = require('node:fs/promises');
const path = require('node:path');
const sharp = require(process.env.SHARP_MODULE_PATH || 'sharp');

const root = path.resolve(__dirname, '..');
const appSource = path.join(root, 'assets/brand/app-icon.svg');
const faviconSource = path.join(root, 'assets/brand/favicon.svg');
const catalog = path.join(root, 'client/ios/Runner/Assets.xcassets/AppIcon.appiconset');
const web = path.join(root, 'web/public');

async function raster(source, target, size, transparent = false) {
  let image = sharp(source, { density: 1200 }).resize(size, size, {
    fit: 'contain', background: transparent ? '#00000000' : '#f2ede2',
  });
  if (!transparent) image = image.flatten({ background: '#f2ede2' }).removeAlpha();
  await image.png().toFile(target);
  const metadata = await sharp(target).metadata();
  if (metadata.width !== size || metadata.height !== size || metadata.hasAlpha !== transparent) {
    throw new Error(`Invalid icon output: ${path.basename(target)}`);
  }
}

async function main() {
  const contents = JSON.parse(await fs.readFile(path.join(catalog, 'Contents.json'), 'utf8'));
  const written = new Set();
  for (const icon of contents.images) {
    if (!icon.filename || written.has(icon.filename)) continue;
    const size = Number(icon.size.split('x')[0]) * Number(icon.scale.replace('x', ''));
    await raster(appSource, path.join(catalog, icon.filename), size);
    written.add(icon.filename);
  }
  await fs.copyFile(faviconSource, path.join(web, 'favicon.svg'));
  for (const size of [16, 32]) {
    await raster(faviconSource, path.join(web, `favicon-${size}.png`), size, true);
  }
  await raster(faviconSource, path.join(web, 'apple-touch-icon.png'), 180);
  console.log(`Exported and verified ${written.size} iOS icons and web favicons.`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});

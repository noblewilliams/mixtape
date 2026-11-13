import { test } from 'node:test'
import { strict as assert } from 'node:assert'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { existsSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { IOS_APP_ID, writeRoutingFiles, verifyRouting } from './site-routing.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))

async function withOutput(fn) {
  const dir = await mkdtemp(join(tmpdir(), 'mixtape-site-'))
  try { await fn(dir) } finally { await rm(dir, { recursive: true, force: true }) }
}

test('the app id is the iOS team and bundle id', () => {
  assert.equal(IOS_APP_ID, '8W34T9PPYH.com.noble.mixtape')
})

test('writes the association file as JSON with no extension', () => withOutput(async dir => {
  await writeRoutingFiles(dir)
  const json = JSON.parse(await readFile(join(dir, '.well-known/apple-app-site-association'), 'utf8'))
  assert.deepEqual(json, {
    applinks: { details: [{ appIDs: ['8W34T9PPYH.com.noble.mixtape'], components: [{ '/': '/m/*' }] }] },
  })
  assert.ok(!existsSync(join(dir, '.well-known/apple-app-site-association.json')))
}))

test('orders _redirects: auth proxy, shared links, app, catch-all', () => withOutput(async dir => {
  await writeRoutingFiles(dir)
  const lines = (await readFile(join(dir, '_redirects'), 'utf8')).trim().split('\n')
  assert.deepEqual(lines.map(line => line.split(/\s+/)[0]), ['/api/auth/*', '/m/*', '/app/*', '/*'])
  assert.equal(lines[1], '/m/* /app/index.html 200')
  assert.match(lines[0], /200!$/)
  // Non-forced rewrites never shadow a file that exists, such as the association file.
  for (const line of lines.slice(1)) assert.doesNotMatch(line, /!$/)
}))

test('verifyRouting passes on written output', () => withOutput(async dir => {
  await writeRoutingFiles(dir)
  await verifyRouting(dir)
}))

test('verifyRouting fails when the association file is missing', () => withOutput(async dir => {
  await writeRoutingFiles(dir)
  await rm(join(dir, '.well-known'), { recursive: true })
  await assert.rejects(verifyRouting(dir), /apple-app-site-association/)
}))

test('verifyRouting fails when /m/* is missing or after the catch-all', () => withOutput(async dir => {
  await writeRoutingFiles(dir)
  const path = join(dir, '_redirects')
  const lines = (await readFile(path, 'utf8')).trim().split('\n')
  await writeFile(path, lines.filter(line => !line.startsWith('/m/')).join('\n') + '\n')
  await assert.rejects(verifyRouting(dir), /\/m\/\*/)
  await writeFile(path, [...lines.filter(line => !line.startsWith('/m/')), lines[1]].join('\n') + '\n')
  await assert.rejects(verifyRouting(dir), /\/m\/\*/)
}))

test('netlify.toml serves the association file as JSON and runs the preview on /m/*', () => {
  const toml = readFileSync(join(root, 'netlify.toml'), 'utf8')
  assert.match(toml, /\[\[headers\]\]\s*\n\s*for = "\/\.well-known\/apple-app-site-association"\s*\n\s*\[headers\.values\]\s*\n\s*Content-Type = "application\/json"/)
  assert.match(toml, /\[\[edge_functions\]\]\s*\n\s*path = "\/m\/\*"\s*\n\s*function = "shared-mix-og"/)
  // base = "web", so the edge functions directory is resolved from web/.
  assert.match(toml, /edge_functions = "\.\.\/netlify\/edge-functions"/)
  assert.ok(existsSync(join(root, 'netlify/edge-functions/shared-mix-og.ts')))
})

test('every tape colour has a preview card', () => {
  const source = readFileSync(join(root, 'server/src/dj/tape-colors.ts'), 'utf8')
  const colors = [...source.matchAll(/'#([0-9a-f]{6})'/g)].map(match => match[1])
  assert.equal(colors.length, 48)
  for (const hex of [...colors, '3f4851']) {
    const path = join(root, `web/public/og/tape-${hex}.png`)
    assert.ok(existsSync(path), `missing card for #${hex}`)
    const png = readFileSync(path)
    assert.equal(png.readUInt32BE(16), 600, 'card width')
    assert.equal(png.readUInt32BE(20), 600, 'card height')
  }
})

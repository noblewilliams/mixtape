import { readFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { strict as assert } from 'node:assert'
import { REDIRECTS, verifyRouting } from './site-routing.mjs'
const root = fileURLToPath(new URL('../dist/', import.meta.url))
const landing = readFileSync(`${root}index.html`, 'utf8')
const app = readFileSync(`${root}app/index.html`, 'utf8')
// Static page: Netlify serves an existing file before the non-forced /* rewrite.
const privacy = readFileSync(`${root}privacy/index.html`, 'utf8')
assert.match(landing, /href="\/app\/"/)
assert.match(app, /src="\/app\/assets\//)
const landingScript = landing.match(/src="\/(assets\/[^"]+\.js)"/)?.[1]
assert.ok(landingScript, 'Landing script not found')
assert.ok(/["`']\/privacy\/["`']/.test(readFileSync(`${root}${landingScript}`, 'utf8')), 'Landing footer must link /privacy/')
assert.match(privacy, /<h1>Privacy policy<\/h1>/)
assert.doesNotMatch(privacy, /<script/)
for (const html of [landing, app, privacy]) {
  for (const [, path] of html.matchAll(/(?:src|href)="(\/[^"?#]+)"/g)) {
    if (path === '/app/' || path === '/') continue
    assert.ok(existsSync(`${root}${path.slice(1)}`), `Missing built asset: ${path}`)
  }
}
assert.equal(readFileSync(`${root}_redirects`, 'utf8'), [...REDIRECTS, ''].join('\n'))
await verifyRouting(root)
console.log('Verified landing, privacy page, application, asset paths, auth routing and shared links')

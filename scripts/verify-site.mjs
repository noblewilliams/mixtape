import { readFileSync, existsSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { strict as assert } from 'node:assert'
const root = fileURLToPath(new URL('../dist/', import.meta.url))
const landing = readFileSync(`${root}index.html`, 'utf8')
const app = readFileSync(`${root}app/index.html`, 'utf8')
assert.match(landing, /href="\/app\/"/)
assert.match(app, /src="\/app\/assets\//)
for (const html of [landing, app]) {
  for (const [, path] of html.matchAll(/(?:src|href)="(\/[^"?#]+)"/g)) {
    if (path === '/app/') continue
    assert.ok(existsSync(`${root}${path.slice(1)}`), `Missing built asset: ${path}`)
  }
}
assert.equal(readFileSync(`${root}_redirects`, 'utf8'), '/api/auth/* https://mixtape-api.goalympics.workers.dev/api/auth/:splat 200!\n/app /app/ 301!\n/app/* /app/index.html 200\n/* /index.html 200\n')
console.log('Verified both entry points, asset paths and auth routing')

import { execFileSync } from 'node:child_process'
import { cp, mkdir, rm, readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'
import { join } from 'node:path'
import { verifyRouting, writeRoutingFiles } from './site-routing.mjs'

const root = fileURLToPath(new URL('../', import.meta.url))
const output = join(root, 'dist')
const env = { ...process.env, VITE_APP_URL: '/app/' }
execFileSync('npm', ['run', 'build'], { cwd: join(root, 'landing'), env, stdio: 'inherit' })
execFileSync('npm', ['run', 'build', '--', '--base=/app/'], { cwd: join(root, 'web'), env, stdio: 'inherit' })
await rm(output, { recursive: true, force: true })
await mkdir(output, { recursive: true })
await cp(join(root, 'landing/dist'), output, { recursive: true })
await cp(join(root, 'web/dist'), join(output, 'app'), { recursive: true })
// Only the root routing file is used by Netlify. Keep auth on its existing origin.
await rm(join(output, 'app/_redirects'), { force: true })
// Association file (universal links) and _redirects; see site-routing.mjs for ordering.
await writeRoutingFiles(output)
await verifyRouting(output)
const app = await readFile(join(output, 'app/index.html'), 'utf8')
if (!app.includes('/app/assets/')) throw new Error('Application assets must use the /app/ base')
console.log('Built landing at / and application at /app/')

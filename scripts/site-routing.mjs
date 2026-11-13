import { mkdir, readFile, writeFile } from 'node:fs/promises'
import { join } from 'node:path'

// <Team ID>.<bundle id> from client/ios/Runner.xcodeproj (DEVELOPMENT_TEAM, PRODUCT_BUNDLE_IDENTIFIER).
export const IOS_APP_ID = '8W34T9PPYH.com.noble.mixtape'
export const ASSOCIATION_PATH = '.well-known/apple-app-site-association'
const AUTH_ORIGIN = 'https://mixtape-api.goalympics.workers.dev'

// Order matters: Netlify applies the first match. Only the auth proxy is forced (!); the
// rest are non-forced rewrites, which Netlify skips whenever a file exists at the path,
// so /* never shadows built files such as the association file.
export const REDIRECTS = [
  `/api/auth/* ${AUTH_ORIGIN}/api/auth/:splat 200!`,
  '/m/* /app/index.html 200',
  '/app/* /app/index.html 200',
  '/* /index.html 200',
]

export const association = () => ({
  applinks: { details: [{ appIDs: [IOS_APP_ID], components: [{ '/': '/m/*' }] }] },
})

export async function writeRoutingFiles(output) {
  await mkdir(join(output, '.well-known'), { recursive: true })
  await writeFile(join(output, ASSOCIATION_PATH), JSON.stringify(association()))
  await writeFile(join(output, '_redirects'), [...REDIRECTS, ''].join('\n'))
}

export async function verifyRouting(output) {
  let json
  try {
    json = JSON.parse(await readFile(join(output, ASSOCIATION_PATH), 'utf8'))
  } catch (error) {
    throw new Error(`Missing or invalid ${ASSOCIATION_PATH}: ${error.message}`)
  }
  const details = json?.applinks?.details?.[0]
  if (!details?.appIDs?.includes(IOS_APP_ID) || details.components?.[0]?.['/'] !== '/m/*') {
    throw new Error(`${ASSOCIATION_PATH} must link ${IOS_APP_ID} to /m/*`)
  }
  const sources = (await readFile(join(output, '_redirects'), 'utf8')).trim().split('\n').map(line => line.split(/\s+/)[0])
  const shared = sources.indexOf('/m/*')
  if (shared < 0 || shared > sources.indexOf('/app/*') || shared > sources.indexOf('/*')) {
    throw new Error('_redirects must rewrite /m/* to the app before the catch-all rules')
  }
}

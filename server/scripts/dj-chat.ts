/**
 * dj-chat — talk to your live DJ from the terminal.
 *
 * Usage (from server/):  npm run dj
 * Signs in as the founder (first user row) by minting a session token against
 * the prod DB using .dev.vars credentials, then chats with the DEPLOYED worker.
 *
 * Commands inside the chat:
 *   /new <prompt>   start a fresh session with that prompt
 *   /sessions       list your sessions
 *   /open <n>       switch to session n from the last /sessions list
 *   /queue          reprint the current queue
 *   /quit           exit
 * Anything else is sent to the DJ as a message in the current session.
 */
import { createInterface } from 'node:readline/promises'
import { readFileSync } from 'node:fs'
import { neon } from '@neondatabase/serverless'
import { drizzle } from 'drizzle-orm/neon-http'
import * as schema from '../src/db/schema'
import { createAuth } from '../src/auth/create-auth'

const BASE = process.env.DJ_BASE ?? 'https://mixtape-api.goalympics.workers.dev'

function devVars(): Record<string, string> {
  const out: Record<string, string> = {}
  for (const line of readFileSync(new URL('../.dev.vars', import.meta.url), 'utf8').split('\n')) {
    const i = line.indexOf('=')
    if (i > 0 && !line.startsWith('#')) {
      const key = line.slice(0, i)
      let value = line.slice(i + 1).trim()
      // Strip a single layer of matching surrounding quotes — a quoted
      // DATABASE_URL would otherwise reach neon() with the quote characters
      // still attached, which throws with the full connection string
      // (credentials included) embedded in the error message.
      if (
        value.length >= 2 &&
        ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))
      ) {
        value = value.slice(1, -1)
      }
      out[key] = value
    }
  }
  return out
}

async function mintToken(): Promise<string> {
  const env = devVars()
  const db = drizzle(neon(env.DATABASE_URL), { schema })
  const auth = createAuth(db, {
    BETTER_AUTH_SECRET: env.BETTER_AUTH_SECRET,
    BETTER_AUTH_URL: BASE,
    APPLE_BUNDLE_ID: env.APPLE_BUNDLE_ID,
  })
  const ctx = await (auth as { $context: Promise<{ internalAdapter: { createSession(userId: string, req: undefined): Promise<{ token: string }> } }> }).$context
  const [founder] = await db.select().from(schema.user)
  if (!founder) throw new Error('no user in the database — sync the app first')
  const { token } = await ctx.internalAdapter.createSession(founder.id, undefined)
  return token
}

type QueueTrack = { position: number; title: string; artist: string; reason: string | null }

function printQueue(queue: QueueTrack[]) {
  if (!queue.length) return console.log('  (queue is empty)')
  for (const t of queue) {
    const reason = t.reason ? `  · ${t.reason}` : ''
    console.log(`  ${String(t.position + 1).padStart(2)}. ${t.title} — ${t.artist}${reason}`)
  }
}

async function api(token: string, method: string, path: string, body?: unknown) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    headers: { Authorization: `Bearer ${token}`, 'content-type': 'application/json' },
    body: body ? JSON.stringify(body) : undefined,
  })
  const json = (await res.json().catch(() => ({}))) as Record<string, unknown>
  return { status: res.status, json }
}

async function main() {
  console.log(`mixtape dj-chat → ${BASE}`)
  const token = await mintToken()
  const rl = createInterface({ input: process.stdin, output: process.stdout })
  let sessionId: string | null = null
  let lastList: Array<{ id: string; title: string }> = []

  const listSessions = async () => {
    const { json } = await api(token, 'GET', '/sessions')
    lastList = (json.sessions as typeof lastList) ?? []
    lastList.forEach((s, i) => console.log(`  [${i + 1}] ${s.title}`))
    if (!lastList.length) console.log('  (no sessions yet — /new <prompt> to start one)')
  }

  console.log("type a prompt to start (or /sessions to resume one), /quit to exit\n")
  for (;;) {
    const line = (await rl.question(sessionId ? 'you> ' : 'new session> ')).trim()
    if (!line) continue
    if (line === '/quit') break
    if (line === '/sessions') { await listSessions(); continue }
    if (line.startsWith('/open ')) {
      const n = Number(line.slice(6)) - 1
      if (!lastList[n]) { console.log('  run /sessions first, then /open <n>'); continue }
      sessionId = lastList[n].id
      const { json } = await api(token, 'GET', `/sessions/${sessionId}`)
      console.log(`  opened: ${lastList[n].title}`)
      printQueue((json.queue as QueueTrack[]) ?? [])
      continue
    }
    if (line === '/queue') {
      if (!sessionId) { console.log('  no session open'); continue }
      const { json } = await api(token, 'GET', `/sessions/${sessionId}`)
      printQueue((json.queue as QueueTrack[]) ?? [])
      continue
    }

    const text = line.startsWith('/new ') ? line.slice(5) : line
    const isNew = line.startsWith('/new ') || !sessionId
    process.stdout.write('dj is thinking…')
    const started = Date.now()
    const { status, json } = isNew
      ? await api(token, 'POST', '/sessions', { prompt: text })
      : await api(token, 'POST', `/sessions/${sessionId}/messages`, { text })
    process.stdout.write(`\r${' '.repeat(40)}\r`)

    if (status >= 400) {
      console.log(`  [${status}] ${String(json.message ?? json.error ?? 'request failed')}`)
      continue
    }
    if (isNew) {
      const session = json.session as { id: string }
      sessionId = session.id
      const messages = json.messages as Array<{ role: string; content: string }>
      console.log(`\ndj> ${messages[messages.length - 1]?.content ?? ''}`)
    } else {
      console.log(`\ndj> ${(json.djMessage as { content: string }).content}`)
    }
    printQueue((json.queue as QueueTrack[]) ?? [])
    console.log(`  (${((Date.now() - started) / 1000).toFixed(1)}s)\n`)
  }
  rl.close()
}

main().catch((e) => {
  if (e instanceof Error && /readline was closed/i.test(e.message)) process.exit(0) // EOF = clean exit
  console.error('dj-chat failed:', e instanceof Error ? e.message : e)
  process.exit(1)
})

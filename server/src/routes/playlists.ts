import { Hono } from 'hono'
import type { AppVars } from '../app'
import type { Db } from '../db/types'
import {
  createPlaylistBrowseStore,
  PlaylistBrowseCursorError,
} from '../playlists/browse-store'

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i

function boundedInteger(value: string | undefined, fallback: number, max: number) {
  if (value == null || value === '') return fallback
  if (!/^\d+$/.test(value)) return null
  const parsed = Number(value)
  return Number.isSafeInteger(parsed) && parsed >= 1 && parsed <= max ? parsed : null
}

export function playlistsRoutes(db: Db) {
  const app = new Hono<{ Variables: AppVars }>()
  const store = createPlaylistBrowseStore(db)

  app.get('/', async (c) => {
    const status = c.req.query('status') ?? 'active'
    const limit = boundedInteger(c.req.query('limit'), 30, 100)
    const q = c.req.query('q')?.trim()
    const cursor = c.req.query('cursor')
    if (
      (status !== 'active' && status !== 'all')
      || limit == null
      || (q != null && (q.length > 200 || q.includes('\0')))
      || (cursor != null && cursor.length > 512)
    ) return c.json({ error: 'invalid_request' }, 400)

    try {
      return c.json(await store.list(c.get('user').id, {
        status,
        limit,
        ...(q ? { q } : {}),
        ...(cursor ? { cursor } : {}),
      }))
    } catch (error) {
      if (error instanceof PlaylistBrowseCursorError) {
        return c.json({ error: 'invalid_cursor' }, 400)
      }
      throw error
    }
  })

  app.get('/:id', async (c) => {
    const id = c.req.param('id')
    if (!UUID_RE.test(id)) return c.json({ error: 'not_found' }, 404)
    const limit = boundedInteger(c.req.query('entryLimit'), 200, 200)
    const cursor = c.req.query('entryCursor')
    if (limit == null || (cursor != null && cursor.length > 512)) {
      return c.json({ error: 'invalid_request' }, 400)
    }
    try {
      const result = await store.detail(c.get('user').id, id, {
        limit,
        ...(cursor ? { cursor } : {}),
      })
      return result ? c.json(result) : c.json({ error: 'not_found' }, 404)
    } catch (error) {
      if (error instanceof PlaylistBrowseCursorError) {
        return c.json({ error: 'invalid_cursor' }, 400)
      }
      throw error
    }
  })

  return app
}

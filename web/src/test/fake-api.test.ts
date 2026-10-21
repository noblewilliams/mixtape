import { describe, expect, it } from 'vitest'
import { ApiError } from '../api/client'
import {
  demoAlbumPick,
  demoAlbumRefinedPick,
  demoAlbumRunnersUp,
  demoListenLaterEntries,
} from '../data/demo'
import { createFakeApi } from './fake-api'

describe('fake API album flow', () => {
  it('creates an album session that reopens with the album shape', async () => {
    const api = createFakeApi()
    const created = await api.createSession('An album for the train home, nothing loud.', undefined, undefined, 'album')

    expect(created.session.kind).toBe('album')
    expect(created.queue).toBeUndefined()
    expect(created.version).toBe(1)
    expect(created.pick?.title).toBe('Low Tide Hours')
    expect(created.runnersUp?.map((album) => album.title)).toEqual(['Nightshift Radio', 'Slow Rooms'])

    const detail = await api.getSession(created.session.id)
    expect(detail.queue).toBeUndefined()
    expect(detail.session.kind).toBe('album')
    expect(detail.pick?.id).toBe(demoAlbumPick.id)
    expect(detail.messages.map((message) => message.role)).toEqual(['user', 'dj'])
  })

  it('keeps mix sessions on the mix shape', async () => {
    const api = createFakeApi()
    const created = await api.createSession('A night drive')
    expect(created.queue?.length).toBe(1)
    expect((await api.getSession(created.session.id)).pick).toBeUndefined()
  })

  it('refines, chooses a runner-up and goes back', async () => {
    const api = createFakeApi()
    const { session } = await api.createSession('An album for the train home, nothing loud.', undefined, undefined, 'album')

    const refined = await api.sendMessage(session.id, 'Another, older.')
    expect(refined.queue).toBeUndefined()
    expect(refined.version).toBe(2)
    expect(refined.pick?.id).toBe(demoAlbumRefinedPick.id)
    expect(refined.passed?.map((album) => [album.id, album.version])).toEqual([[demoAlbumPick.id, 1]])

    const chosen = await api.choosePick(session.id, { albumId: demoAlbumRunnersUp[0].id }, 2)
    expect(chosen.version).toBe(3)
    expect(chosen.pick?.id).toBe(demoAlbumRunnersUp[0].id)
    expect(chosen.runnersUp.map((album) => album.id)).not.toContain(demoAlbumRunnersUp[0].id)
    expect(chosen.passed.map((album) => album.id)).toEqual([demoAlbumRefinedPick.id, demoAlbumPick.id])

    await expect(api.choosePick(session.id, { version: 1 }, 2)).rejects.toMatchObject({ status: 409, code: 'stale' })

    const back = await api.choosePick(session.id, { version: 1 }, 3)
    expect(back.version).toBe(4)
    expect(back.pick?.id).toBe(demoAlbumPick.id)
    expect((await api.getSession(session.id)).version).toBe(4)
  })

  it('lists created album sessions with their current pick, newest first', async () => {
    const api = createFakeApi()
    const first = await api.createSession('An album for the train home, nothing loud.', undefined, undefined, 'album')
    const second = await api.createSession('Something for Sunday.', undefined, undefined, 'album')
    await api.sendMessage(first.session.id, 'Another, older.')

    const { sessions } = await api.listSessions()
    expect(sessions.slice(0, 2)).toMatchObject([
      { id: first.session.id, kind: 'album', trackCount: 0, durationMs: 0, pick: { title: 'Harbour Lights', artist: 'Folake Adeyemi', artwork: null } },
      { id: second.session.id, kind: 'album', pick: { title: 'Low Tide Hours' } },
    ])
    expect(sessions[2].kind).toBe('mix')
  })

  it('reports album picks on by default', async () => {
    expect((await createFakeApi().getMe()).albumPicks).toBe(true)
  })
})

describe('fake API Listen later', () => {
  it('starts from seeded entries', async () => {
    const api = createFakeApi({}, { listenLater: demoListenLaterEntries })
    expect((await api.listListenLater()).entries.map((entry) => entry.id))
      .toEqual(demoListenLaterEntries.map((entry) => entry.id))
  })

  it('saves, orders, removes, revives and marks listened', async () => {
    const api = createFakeApi()
    const { session } = await api.createSession('An album for the train home, nothing loud.', undefined, undefined, 'album')
    const [first, second] = [demoAlbumPick, demoAlbumRunnersUp[0]]

    const saved = await api.saveForLater(first.id, session.id)
    expect(saved.entry).toMatchObject({ id: first.id, sessionId: session.id, listenedAt: null, reason: first.reason })
    expect((await api.getSession(session.id)).pick?.savedForLater).toBe(true)

    await api.saveForLater(second.id)
    await api.saveForLater(first.id, session.id)
    expect((await api.listListenLater()).entries.map((entry) => entry.id)).toEqual([second.id, first.id])

    const listened = await api.markListened(second.id)
    const listenedAt = listened.entry.listenedAt
    expect(listenedAt).not.toBeNull()
    expect((await api.markListened(second.id)).entry.listenedAt).toBe(listenedAt)
    expect((await api.listListenLater()).entries.map((entry) => entry.id)).toEqual([first.id, second.id])

    await api.unsaveForLater(first.id)
    expect((await api.listListenLater()).entries.map((entry) => entry.id)).toEqual([second.id])
    expect((await api.getSession(session.id)).pick?.savedForLater).toBe(false)

    await api.saveForLater(first.id)
    expect((await api.listListenLater()).entries.map((entry) => entry.id)).toEqual([first.id, second.id])
    expect(api.calls.filter((call) => call.method === 'saveForLater')).toHaveLength(4)
  })

  it('refuses an unknown album', async () => {
    await expect(createFakeApi().saveForLater('missing')).rejects.toBeInstanceOf(ApiError)
    await expect(createFakeApi().unsaveForLater('missing')).rejects.toMatchObject({ status: 404 })
  })

  it('refuses a source session that never offered the album', async () => {
    const api = createFakeApi()
    const { session } = await api.createSession('An album for the train home, nothing loud.', undefined, undefined, 'album')
    await expect(api.saveForLater(demoListenLaterEntries[0].id, session.id)).rejects.toMatchObject({ status: 404 })
    await expect(api.saveForLater(demoAlbumPick.id, 'no-such-session')).rejects.toMatchObject({ status: 404 })
    expect((await api.listListenLater()).entries).toEqual([])
  })

  it('fills a missing source on a repeat save and rereads the why on revive', async () => {
    const api = createFakeApi()
    const { session } = await api.createSession('An album for the train home, nothing loud.', undefined, undefined, 'album')
    const runnerUp = demoAlbumRunnersUp[0]

    expect((await api.saveForLater(runnerUp.id)).entry).toMatchObject({ sessionId: null, reason: null })
    const filled = await api.saveForLater(runnerUp.id, session.id)
    expect(filled.entry).toMatchObject({ sessionId: session.id, reason: runnerUp.reason })

    await api.unsaveForLater(runnerUp.id)
    const revived = await api.saveForLater(runnerUp.id)
    expect(revived.entry).toMatchObject({ sessionId: session.id, reason: runnerUp.reason })
  })
})

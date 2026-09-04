import { cleanup, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import type { ApiSeedTrack, PostSeedTracksResponse } from '../api/client'
import { createFakeApi } from '../test/fake-api'
import { PasteSongsBox } from './PasteSongsBox'

const GOOD_ONE = 'https://open.spotify.com/track/3n3Ppam7vgaVa1iaRUc9Lp'
const GOOD_TWO = 'spotify:track:7qiZfU4dY1lWllzX7mPBI3'

function renderBox(api = createFakeApi()) {
  render(<PasteSongsBox api={api} />)
  return api
}

describe('PasteSongsBox', () => {
  afterEach(cleanup)

  it('counts pasted lines on the add control and keeps it quiet when empty', () => {
    renderBox()

    expect(screen.getByRole('heading', { name: 'Seed the DJ with songs you love' })).toBeInTheDocument()
    expect(screen.getByText('In Spotify on your computer, select tracks, copy, and paste the links here. One per line.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Add songs' })).toBeDisabled()

    fireEvent.change(screen.getByLabelText('Links'), {
      target: { value: `${GOOD_ONE}\n${GOOD_TWO}?si=x\nhttps://open.spotify.com/track/notARealId` },
    })
    expect(screen.getByRole('button', { name: 'Add 3 songs' })).toBeEnabled()
  })

  it('posts only the recognised ids, lists what resolved, and flags the rest', async () => {
    const response: PostSeedTracksResponse = {
      resolved: [
        { spotifyId: '3n3Ppam7vgaVa1iaRUc9Lp', trackId: 'track-a', title: 'Small Distances', artist: 'Ari Sola' },
        { spotifyId: '7qiZfU4dY1lWllzX7mPBI3', trackId: 'track-b', title: 'Streetlight Weather', artist: 'Juniper North' },
      ],
      unresolved: [],
    }
    const postSeedTracks = vi.fn(async () => response)
    renderBox(createFakeApi({ postSeedTracks }))

    fireEvent.change(screen.getByLabelText('Links'), {
      target: { value: `${GOOD_ONE}\n${GOOD_TWO}\nhttps://open.spotify.com/track/notARealId` },
    })
    fireEvent.click(screen.getByRole('button', { name: 'Add 3 songs' }))

    expect(await screen.findByText('2 songs added')).toBeInTheDocument()
    expect(postSeedTracks).toHaveBeenCalledWith(['3n3Ppam7vgaVa1iaRUc9Lp', '7qiZfU4dY1lWllzX7mPBI3'])
    expect(screen.getByText('Small Distances · Ari Sola · Streetlight Weather · Juniper North')).toBeInTheDocument()
    expect(screen.getByText('1 link not recognised')).toBeInTheDocument()
    expect(screen.getByText('One line isn’t a Spotify track link. Nothing else was affected.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Remove Small Distances' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Remove Streetlight Weather' })).toBeInTheDocument()
    expect(screen.getByLabelText('Links')).toHaveValue('')
  })

  it('does not post when no line is a track link', () => {
    const postSeedTracks = vi.fn()
    renderBox(createFakeApi({ postSeedTracks }))

    fireEvent.change(screen.getByLabelText('Links'), { target: { value: 'hello\nworld' } })
    fireEvent.click(screen.getByRole('button', { name: 'Add 2 songs' }))

    expect(postSeedTracks).not.toHaveBeenCalled()
    expect(screen.getByText('2 links not recognised')).toBeInTheDocument()
  })

  it('shows existing seeds as chips and removes one through the API', async () => {
    const seeds: ApiSeedTrack[] = [
      { trackId: 'track-a', spotifyId: '3n3Ppam7vgaVa1iaRUc9Lp', title: 'Small Distances', artist: 'Ari Sola', album: null },
    ]
    const deleteSeedTrack = vi.fn(async () => ({ removed: true as const, deleted: true }))
    renderBox(createFakeApi({ getSeedTracks: async () => ({ tracks: seeds }), deleteSeedTrack }))

    fireEvent.click(await screen.findByRole('button', { name: 'Remove Small Distances' }))

    await waitFor(() => expect(deleteSeedTrack).toHaveBeenCalledWith('track-a'))
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Remove Small Distances' })).not.toBeInTheDocument())
  })

  it('ignores a second click while a chip removal is in flight', async () => {
    const seeds: ApiSeedTrack[] = [
      { trackId: 'track-a', spotifyId: '3n3Ppam7vgaVa1iaRUc9Lp', title: 'Small Distances', artist: 'Ari Sola', album: null },
    ]
    let release: () => void = () => undefined
    const deleteSeedTrack = vi.fn(
      () =>
        new Promise<{ removed: true; deleted: boolean }>((resolve) => {
          release = () => resolve({ removed: true, deleted: true })
        }),
    )
    renderBox(createFakeApi({ getSeedTracks: async () => ({ tracks: seeds }), deleteSeedTrack }))

    const remove = await screen.findByRole('button', { name: 'Remove Small Distances' })
    fireEvent.click(remove)
    fireEvent.click(remove)

    expect(deleteSeedTrack).toHaveBeenCalledTimes(1)
    expect(remove).toBeDisabled()
    release()
    await waitFor(() => expect(screen.queryByRole('button', { name: 'Remove Small Distances' })).not.toBeInTheDocument())
  })
})

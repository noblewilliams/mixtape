// Invented Spotify export records for parser tests. Every name here is made up.

export const HISTORY_DIR = 'Spotify Extended Streaming History'
export const ACCOUNT_DIR = 'Spotify Account Data'

export const TRACK_A = 'GlassCorridor000000001'
export const TRACK_B = 'HarborStatic0000000001'

export function historyRow(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    ts: '2025-01-15T18:30:00Z',
    platform: 'android',
    ms_played: 187000,
    conn_country: 'NG',
    ip_addr: '203.0.113.7',
    master_metadata_track_name: 'Glass Corridor',
    master_metadata_album_artist_name: 'Harbor Static',
    master_metadata_album_album_name: 'Night Signals',
    spotify_track_uri: `spotify:track:${TRACK_A}`,
    episode_name: null,
    episode_show_name: null,
    spotify_episode_uri: null,
    audiobook_title: null,
    audiobook_uri: null,
    audiobook_chapter_uri: null,
    audiobook_chapter_title: null,
    reason_start: 'clickrow',
    reason_end: 'trackdone',
    shuffle: false,
    skipped: false,
    offline: false,
    offline_timestamp: null,
    incognito_mode: false,
    ...overrides,
  }
}

export const LIBRARY = {
  tracks: [{ artist: 'Harbor Static', album: 'Night Signals', track: 'Glass Corridor', uri: `spotify:track:${TRACK_A}` }],
  artists: [{ name: 'Harbor Static', uri: 'spotify:artist:HarborStaticArtist0001' }],
}

export const PLAYLISTS = {
  playlists: [
    {
      name: 'Corridor Walks',
      lastModifiedDate: '2026-02-01',
      items: [
        {
          track: { trackName: 'Glass Corridor', artistName: 'Harbor Static', albumName: 'Night Signals', trackUri: `spotify:track:${TRACK_A}` },
          episode: null,
          localTrack: null,
          addedDate: '2026-01-10',
        },
      ],
      description: '',
      numberOfFollowers: 0,
    },
  ],
}

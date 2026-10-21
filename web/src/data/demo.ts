import type { ApiAlbum, ApiListenLaterEntry } from '../api/client'
import type { DjMessage, DjSession, QueueTrack } from '../domain'

const tapeNames = [
  ['blue-hour', 'Blue hour, windows down', 'just now', 15, '#3f4851'],
  ['sunday-kitchen', 'Sunday kitchen radio', 'yesterday', 22, '#76584f'],
  ['soft-landing', 'Soft landing after work', '3 days ago', 13, '#596454'],
  ['whole-apartment', 'Clean the whole apartment', 'last week', 31, '#51434f'],
  ['old-friends', 'Old friends', '9 days ago', 18, '#d1c479'],
  ['after-midnight', 'After midnight', '2 weeks ago', 20, '#3e4850'],
  ['no-rush-home', 'No rush home', '2 weeks ago', 16, '#ddd5c9'],
  ['golden-morning', 'Golden morning', '3 weeks ago', 21, '#b56e68'],
  ['small-victories', 'Small victories', '3 weeks ago', 14, '#3e4850'],
  ['abuja-rain', 'Abuja after rain', '4 weeks ago', 19, '#d1c479'],
  ['easy-saturday', 'Easy Saturday', 'last month', 17, '#ddd5c9'],
  ['long-way', 'Long way around', 'last month', 25, '#b56e68'],
  ['windows-open', 'Windows open', 'last month', 16, '#ddd5c9'],
  ['first-light', 'First light', '2 months ago', 12, '#ddd5c9'],
  ['warm-kitchen', 'Warm kitchen', '2 months ago', 24, '#d1c479'],
  ['good-company', 'Good company', '2 months ago', 28, '#b56e68'],
  ['deep-clean', 'Deep clean', '3 months ago', 32, '#ddd5c9'],
  ['slow-start', 'Slow start', '3 months ago', 11, '#3e4850'],
  ['road-home', 'Road home', '3 months ago', 20, '#ddd5c9'],
] as const

export const demoSessions: DjSession[] = tapeNames.map(
  ([id, title, ageLabel, trackCount, caseColor], index) => ({
    id,
    kind: 'mix',
    title,
    status: 'active',
    queueVersion: 3,
    notPersonal: false,
    updatedAt: new Date(Date.UTC(2026, 7, 30 - index)).toISOString(),
    ageLabel,
    trackCount,
    durationLabel: `${Math.max(38, Math.round(trackCount * 3.6))} min`,
    caseColor,
    stockColor: index % 4 === 1 ? '#eee6d7' : '#f2ede2',
  }),
)

export const demoMessages: DjMessage[] = [
  {
    id: 'message-1',
    role: 'user',
    content: 'Night drive through Abuja. Familiar and warm, but nothing that feels sleepy.',
    createdAt: '2026-08-30T17:00:00.000Z',
  },
  {
    id: 'message-2',
    role: 'dj',
    content:
      'I kept the opening close to songs you already know, then let the rhythm find the road after track five. It stays warm all the way through—no ballads.',
    queueVersion: 1,
    createdAt: '2026-08-30T17:00:08.000Z',
  },
  {
    id: 'message-3',
    role: 'user',
    content: 'Give the middle a little more movement.',
    createdAt: '2026-08-30T17:04:00.000Z',
  },
  {
    id: 'message-4',
    role: 'dj',
    content:
      'I moved the slower stretch earlier and brought three brighter tracks into the middle. The opening and landing are unchanged.',
    queueVersion: 2,
    createdAt: '2026-08-30T17:04:08.000Z',
  },
  {
    id: 'message-5',
    role: 'user',
    content: 'More like track six, but older.',
    createdAt: '2026-08-30T17:08:00.000Z',
  },
]

export const demoQueue: QueueTrack[] = [
  ['Sweetest Taboo', 'Sade', 'A low-lit opening that still has forward motion.'],
  ['Essence', 'Wizkid feat. Tems', 'A familiar lift without breaking the warmth.'],
  ['Anybody', 'Burna Boy', 'The first real step onto the road.'],
  ['Woman', 'Rema', 'Keeps the middle loose and rhythmic.'],
  ['Energy', 'Sampa the Great', 'A brighter centre without turning frantic.'],
  ['Love Is Stronger Than Pride', 'Sade', 'Returns to the tape’s patient confidence.'],
  ['Doyin', 'Mr Eazi feat. Simi', 'A gentle release after the brighter stretch.'],
  ['Free Mind', 'Tems', 'Lets the tape land without feeling sleepy.'],
  ['Soweto', 'Victony & Tempoe', 'Keeps the road moving with an easy pulse.'],
  ['Fall', 'Davido', 'A familiar sing-along placed after the midpoint.'],
  ['Finesse', 'Pheelz feat. BNXN', 'Adds bounce without pushing the tempo too far.'],
  ['Smile', 'Wizkid feat. H.E.R.', 'Softens the last third while keeping it warm.'],
  ['On the Low', 'Burna Boy', 'A restrained late-night groove.'],
  ['Try Me', 'Tems', 'Adds tension before the final release.'],
  ['By Your Side', 'Sade', 'A calm, familiar closer for the drive home.'],
].map(([title, artist, reason], index) => ({
  position: index,
  trackId: `track-${index + 1}`,
  appleId: `apple-${index + 1}`,
  spotifyId: null,
  title,
  artist,
  reason,
  durationMs: 185_000 + index * 4_000,
}))

export function makeConversationFor(session: DjSession): DjMessage[] {
  if (session.id === demoSessions[0].id) return demoMessages

  return [
    {
      id: `${session.id}-prompt`,
      role: 'user',
      content: `Make me something that feels like ${session.title.toLowerCase()}.`,
      createdAt: session.updatedAt,
    },
    {
      id: `${session.id}-reply`,
      role: 'dj',
      content:
        'I kept the shape personal: a familiar opening, a little room to move in the middle, and a landing that does not overstay the moment.',
      queueVersion: session.queueVersion,
      createdAt: session.updatedAt,
    },
  ]
}

// Album picks (board 2026-10-20). Artwork stays null: no external URLs in fixtures.
const albumId = (n: number) => `5a1b0000-0000-4000-8000-${String(n).padStart(12, '0')}`

function demoAlbum(
  n: number,
  fields: Pick<ApiAlbum, 'title' | 'artist' | 'releaseYear' | 'type' | 'trackCount' | 'reason' | 'newToThem'> & { minutes: number },
): ApiAlbum {
  const { minutes, ...rest } = fields
  return {
    id: albumId(n),
    upc: `19000000000${n}`,
    appleId: `157000000${n}`,
    durationMs: minutes * 60_000,
    artwork: null,
    savedForLater: false,
    version: 1,
    ...rest,
  }
}

export const demoAlbumPick = demoAlbum(1, {
  title: 'Low Tide Hours', artist: 'Mara Ilesanmi', releaseYear: 2019, type: 'album', trackCount: 11, minutes: 44,
  newToThem: false, reason: 'Slow and warm, and you already know three of its songs.',
})

export const demoAlbumRunnersUp: ApiAlbum[] = [
  demoAlbum(2, {
    title: 'Nightshift Radio', artist: 'The Quiet Parade', releaseYear: 2016, type: 'ep', trackCount: 5, minutes: 22,
    newToThem: true, reason: 'Shorter and a little brighter, from a band you have not played yet.',
  }),
  demoAlbum(3, {
    title: 'Slow Rooms', artist: 'Mara Ilesanmi', releaseYear: 2014, type: 'album', trackCount: 10, minutes: 41,
    newToThem: false, reason: 'Her earlier record, sparer and just as warm.',
  }),
]

export const demoAlbumRefinedPick: ApiAlbum = {
  ...demoAlbum(4, {
    title: 'Harbour Lights', artist: 'Folake Adeyemi', releaseYear: 1978, type: 'album', trackCount: 8, minutes: 36,
    newToThem: true, reason: 'Older, same hush, and an artist you have never played.',
  }),
  version: 2,
}

export const demoShelfAlbums: ApiAlbum[] = [
  demoAlbum(5, {
    title: 'Kitchen Radio Sessions', artist: 'Odun & the Weather', releaseYear: 2021, type: 'live', trackCount: 12, minutes: 58,
    newToThem: true, reason: 'Recorded live in one room, loose and close.',
  }),
  demoAlbum(6, {
    title: 'Every Room Is a Harbour, Part Two: The Long Way Round', artist: 'The Quiet Parade', releaseYear: 2023,
    type: 'compilation', trackCount: 18, minutes: 72, newToThem: false, reason: 'A long, patient collection for when the trip runs over.',
  }),
]

export const demoAlbums: ApiAlbum[] = [demoAlbumPick, ...demoAlbumRunnersUp, demoAlbumRefinedPick, ...demoShelfAlbums]

export function toDemoListenLaterEntry(
  { newToThem: _newToThem, reason: _reason, savedForLater: _saved, version: _version, ...album }: ApiAlbum,
  entry: Pick<ApiListenLaterEntry, 'savedAt'> & Partial<Pick<ApiListenLaterEntry, 'sessionId' | 'listenedAt' | 'reason'>>,
): ApiListenLaterEntry {
  return { ...album, sessionId: null, listenedAt: null, reason: null, ...entry }
}

/** The shelf as GET /me/listen-later returns it: newest saved first, nothing listened yet. */
export const demoListenLaterEntries: ApiListenLaterEntry[] = [
  toDemoListenLaterEntry(demoShelfAlbums[0], { savedAt: '2026-10-19T19:30:00.000Z' }),
  toDemoListenLaterEntry(demoShelfAlbums[1], { savedAt: '2026-10-12T08:15:00.000Z' }),
]

export const demoAlbumPrompt = 'An album for the train home, nothing loud.'
export const demoAlbumReply =
  'One record, start to finish. Slow and warm, and it sits exactly where a tired train does. You already have three of its songs, so it will feel half familiar.'
export const demoAlbumRefinePrompt = 'Another, older.'
export const demoAlbumRefineReply =
  'Older then. Nineteen seventy-eight, and it has the same hush. You do not have any of it yet.'

export const demoAlbumMessages: DjMessage[] = [
  { id: 'album-message-1', role: 'user', content: demoAlbumPrompt, createdAt: '2026-10-20T18:00:00.000Z' },
  { id: 'album-message-2', role: 'dj', content: demoAlbumReply, queueVersion: 1, createdAt: '2026-10-20T18:00:09.000Z' },
  { id: 'album-message-3', role: 'user', content: demoAlbumRefinePrompt, createdAt: '2026-10-20T18:03:00.000Z' },
  { id: 'album-message-4', role: 'dj', content: demoAlbumRefineReply, queueVersion: 2, createdAt: '2026-10-20T18:03:08.000Z' },
]

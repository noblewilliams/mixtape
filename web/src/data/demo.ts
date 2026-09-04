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

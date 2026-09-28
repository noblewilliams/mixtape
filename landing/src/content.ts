export const demoTracks: Record<
  string,
  { artist: string; duration: string; artwork: string; url: string }
> = {
  Nightcall: {
    artist: "Kavinsky & Lovefoxxx",
    duration: "4:20",
    artwork:
      "https://is1-ssl.mzstatic.com/image/thumb/Music124/v4/0e/4a/c2/0e4ac256-3e90-1131-2693-bf1098e6a753/886443160507.jpg/100x100bb.jpg",
    url: "https://music.apple.com/us/album/nightcall/455448129?i=455448132&uo=4",
  },
  "Space Song": {
    artist: "Beach House",
    duration: "5:20",
    artwork:
      "https://is1-ssl.mzstatic.com/image/thumb/Music125/v4/09/e0/d5/09e0d559-0682-f0f0-5e0c-3cd11e3114fd/beachhouse_depressioncherry_2400_300.jpg/100x100bb.jpg",
    url: "https://music.apple.com/us/album/space-song/997913392?i=997914096&uo=4",
  },
  "A Real Hero": {
    artist: "College",
    duration: "4:28",
    artwork:
      "https://is1-ssl.mzstatic.com/image/thumb/Music124/v4/0e/4a/c2/0e4ac256-3e90-1131-2693-bf1098e6a753/886443160507.jpg/100x100bb.jpg",
    url: "https://music.apple.com/us/album/a-real-hero-feat-electric-youth/455448129?i=455448137&uo=4",
  },
  "Midnight City": {
    artist: "M83",
    duration: "4:01",
    artwork:
      "https://is1-ssl.mzstatic.com/image/thumb/Music211/v4/cb/7b/a9/cb7ba903-b5f1-cc21-90db-7a81b7aa0997/724596951057.jpg/100x100bb.jpg",
    url: "https://music.apple.com/us/album/midnight-city/828259375?i=828259377&uo=4",
  },
};

export const moments = [
  {
    name: "The long way home",
    context: "For the drive",
    color: "#a6b6d1",
    prompt:
      "I need a mix for a late drive home, a little dreamy and nostalgic.",
    response:
      "Windows down. Nowhere to rush. Here’s a little company for the road.",
    songs: ["Nightcall", "Space Song", "A Real Hero"],
    refined: ["Space Song", "Midnight City", "A Real Hero"],
  },
] as const;

export const questions = [
  {
    question: "What makes this different from a playlist?",
    answer:
      "Tell your DJ what you feel like hearing, then refine it together. Play the mix now or save it as a playlist.",
  },
  {
    question: "Does it work with Apple Music and Spotify?",
    answer:
      "Apple Music supports library sync, playback and playlist creation with an active subscription. Bring Spotify playlists and history through file imports; there’s no live Spotify connection.",
  },
  {
    question: "Should I use the browser or download the app?",
    answer:
      "Start in your browser. We recommend the app for Apple Music library sync, including per-song play counts.",
  },
  {
    question: "Will Mixtape change my existing playlists?",
    answer:
      "No. Your existing playlists stay as they are. Saving a mix creates a new one.",
  },
  {
    question: "Can I control what the DJ remembers?",
    answer:
      "Yes. Ask it to remember a preference. Review or remove notes in “What the DJ knows”.",
  },
];

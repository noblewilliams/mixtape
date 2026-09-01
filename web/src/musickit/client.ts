import {
  fetchMusicSnapshot,
  type MusicSnapshot,
  type MusicSnapshotProgress,
} from './library'

export type MusicKitToken = {
  developerToken: string
  expiresAt: number
}

export type MusicKitInstance = {
  readonly isAuthorized: boolean
  authorize: () => Promise<string | void>
  setQueue: (options: { songs: string[] }) => Promise<unknown>
  play: () => void | Promise<void>
  pause: () => void | Promise<void>
}

export type MusicKitGlobal = {
  configure: (configuration: {
    developerToken: string
    app: { name: string; build: string }
  }) => Promise<MusicKitInstance | void>
  getInstance: () => MusicKitInstance
}

export type MusicKitClient = {
  connect: () => Promise<void>
  snapshot: (options: {
    signal: AbortSignal
    onProgress: (progress: MusicSnapshotProgress) => void
  }) => Promise<MusicSnapshot>
  play: (appleIds: string[]) => Promise<void>
  pause: () => Promise<void>
  createPlaylist: (name: string, appleIds: string[]) => Promise<void>
}

export type MusicKitClientErrorCode =
  | 'unavailable'
  | 'configuration_failed'
  | 'authorization_cancelled'
  | 'authorization_failed'
  | 'not_connected'
  | 'empty_queue'
  | 'playback_failed'
  | 'playlist_failed'
  | 'library_failed'

export class MusicKitClientError extends Error {
  readonly code: MusicKitClientErrorCode
  readonly cause?: unknown

  constructor(code: MusicKitClientErrorCode, message: string, cause?: unknown) {
    super(message)
    this.name = 'MusicKitClientError'
    this.code = code
    this.cause = cause
  }
}

const MUSICKIT_SCRIPT_URL = 'https://js-cdn.music.apple.com/musickit/v3/musickit.js'
const PLAYLIST_URL = 'https://api.music.apple.com/v1/me/library/playlists'
const APPLE_API_ORIGIN = 'https://api.music.apple.com'
const TOKEN_REFRESH_MARGIN_SECONDS = 30

let musicKitLoadPromise: Promise<MusicKitGlobal> | null = null

function currentMusicKit(): MusicKitGlobal | undefined {
  return (window as Window & { MusicKit?: MusicKitGlobal }).MusicKit
}

export function loadMusicKitScript(): Promise<MusicKitGlobal> {
  const loaded = currentMusicKit()
  if (loaded) return Promise.resolve(loaded)
  if (musicKitLoadPromise) return musicKitLoadPromise

  const pending = new Promise<MusicKitGlobal>((resolve, reject) => {
    let script = document.querySelector<HTMLScriptElement>(`script[src="${MUSICKIT_SCRIPT_URL}"]`)

    const cleanup = () => {
      document.removeEventListener('musickitloaded', onLoaded)
      script?.removeEventListener('error', onError)
      window.clearTimeout(timeout)
    }
    const fail = (message: string, cause?: unknown) => {
      cleanup()
      if (script?.dataset.mixtapeMusickit === 'true') script.remove()
      reject(new MusicKitClientError('unavailable', message, cause))
    }
    const onLoaded = () => {
      const musicKit = currentMusicKit()
      if (!musicKit) {
        fail('Apple Music loaded without exposing MusicKit.')
        return
      }
      cleanup()
      resolve(musicKit)
    }
    const onError = (event: Event) => fail('Apple Music could not be loaded.', event)
    const timeout = window.setTimeout(() => fail('Apple Music took too long to load.'), 15_000)

    document.addEventListener('musickitloaded', onLoaded)

    if (!script) {
      script = document.createElement('script')
      script.src = MUSICKIT_SCRIPT_URL
      script.async = true
      script.dataset.mixtapeMusickit = 'true'
      document.head.append(script)
    }
    script.addEventListener('error', onError, { once: true })
  })

  musicKitLoadPromise = pending
  void pending.catch(() => {
    if (musicKitLoadPromise === pending) musicKitLoadPromise = null
  })
  return pending
}

type ConfiguredMusicKit = {
  developerToken: string
  expiresAt: number
  instance: MusicKitInstance
}

type CreateMusicKitClientOptions = {
  getDeveloperToken: () => Promise<MusicKitToken>
  loadMusicKit?: () => Promise<MusicKitGlobal>
  fetchImpl?: typeof fetch
  nowSeconds?: () => number
}

function asClientError(
  error: unknown,
  code: MusicKitClientErrorCode,
  message: string,
): MusicKitClientError {
  return error instanceof MusicKitClientError ? error : new MusicKitClientError(code, message, error)
}

export function createMusicKitClient({
  getDeveloperToken,
  loadMusicKit = loadMusicKitScript,
  fetchImpl = fetch,
  nowSeconds = () => Math.floor(Date.now() / 1000),
}: CreateMusicKitClientOptions): MusicKitClient {
  let configured: ConfiguredMusicKit | null = null
  let configurationPromise: Promise<ConfiguredMusicKit> | null = null
  let musicUserToken: string | null = null

  async function configure(): Promise<ConfiguredMusicKit> {
    if (configured && configured.expiresAt - TOKEN_REFRESH_MARGIN_SECONDS > nowSeconds()) return configured
    if (configurationPromise) return configurationPromise

    configurationPromise = (async () => {
      try {
        const [musicKit, token] = await Promise.all([loadMusicKit(), getDeveloperToken()])
        if (!token.developerToken || token.expiresAt <= nowSeconds()) {
          throw new MusicKitClientError('configuration_failed', 'The Apple Music token is invalid or expired.')
        }
        const instance =
          (await musicKit.configure({
            developerToken: token.developerToken,
            app: { name: 'Mixtape', build: '0.1.0' },
          })) ?? musicKit.getInstance()

        configured = { developerToken: token.developerToken, expiresAt: token.expiresAt, instance }
        return configured
      } catch (error) {
        configured = null
        throw asClientError(error, 'configuration_failed', 'Apple Music could not be prepared.')
      } finally {
        configurationPromise = null
      }
    })()

    return configurationPromise
  }

  async function connect() {
    const { instance } = await configure()
    try {
      const authorizedUser = await instance.authorize()
      if (!authorizedUser) {
        musicUserToken = null
        throw new MusicKitClientError(
          'authorization_cancelled',
          'Apple Music authorization was cancelled.',
        )
      }
      musicUserToken = authorizedUser
    } catch (error) {
      musicUserToken = null
      throw asClientError(error, 'authorization_failed', 'Apple Music authorization did not finish.')
    }
  }

  async function requireConnection(): Promise<ConfiguredMusicKit> {
    const current = await configure()
    if (!musicUserToken) {
      throw new MusicKitClientError('not_connected', 'Connect Apple Music before using this action.')
    }
    return current
  }

  function appleApiUrl(path: string) {
    const url = new URL(path, APPLE_API_ORIGIN)
    if (url.origin !== APPLE_API_ORIGIN || !url.pathname.startsWith('/v1/')) {
      throw new MusicKitClientError('library_failed', 'Apple Music returned an unsafe page link.')
    }
    return url.toString()
  }

  async function requestApple(path: string, signal: AbortSignal) {
    const current = await requireConnection()
    const response = await fetchImpl(appleApiUrl(path), {
      headers: {
        Authorization: `Bearer ${current.developerToken}`,
        'Music-User-Token': musicUserToken!,
      },
      signal,
    })
    if (response.status === 401 || response.status === 403) {
      musicUserToken = null
      throw new MusicKitClientError(
        'authorization_failed',
        'Apple Music authorization has expired.',
      )
    }
    if (!response.ok) throw new Error(`Apple Music returned ${response.status}`)
    const value: unknown = await response.json()
    if (!value || typeof value !== 'object' || !Array.isArray((value as { data?: unknown }).data)) {
      throw new Error('Apple Music returned a malformed response.')
    }
    return value as { data: unknown[]; next?: string; meta?: { total?: number } }
  }

  return {
    connect,
    async snapshot(options) {
      await requireConnection()
      try {
        return await fetchMusicSnapshot({
          request: requestApple,
          signal: options.signal,
          onProgress: options.onProgress,
        })
      } catch (error) {
        throw asClientError(error, 'library_failed', 'Apple Music could not read this library.')
      }
    },
    async play(appleIds) {
      if (appleIds.length === 0) throw new MusicKitClientError('empty_queue', 'This mix has no Apple Music tracks.')
      const { instance } = await requireConnection()
      try {
        await instance.setQueue({ songs: appleIds })
        await Promise.resolve(instance.play())
      } catch (error) {
        throw asClientError(error, 'playback_failed', 'Apple Music could not play this mix.')
      }
    },
    async pause() {
      const { instance } = await requireConnection()
      try {
        await Promise.resolve(instance.pause())
      } catch (error) {
        throw asClientError(error, 'playback_failed', 'Apple Music could not pause this mix.')
      }
    },
    async createPlaylist(name, appleIds) {
      if (appleIds.length === 0) throw new MusicKitClientError('empty_queue', 'This mix has no Apple Music tracks.')
      const current = await requireConnection()

      try {
        const response = await fetchImpl(PLAYLIST_URL, {
          method: 'POST',
          headers: {
            Authorization: `Bearer ${current.developerToken}`,
            'Content-Type': 'application/json',
            'Music-User-Token': musicUserToken!,
          },
          body: JSON.stringify({
            attributes: { name, description: 'Created with Mixtape' },
            relationships: {
              tracks: {
                data: appleIds.map((id) => ({ id, type: 'songs' })),
              },
            },
          }),
        })
        if (!response.ok) {
          if (response.status === 401 || response.status === 403) musicUserToken = null
          throw new Error(`Apple Music returned ${response.status}`)
        }
      } catch (error) {
        throw asClientError(error, 'playlist_failed', 'Apple Music could not create this playlist.')
      }
    },
  }
}

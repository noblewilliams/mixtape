import {
  ApiError,
  type MixtapeApi,
  type PlaybackObservation,
  type PlaybackPreferences,
} from '../api/client'
import type { QueueTrack } from '../domain'
import type { MusicKitClient } from '../musickit/client'
import { ListeningMeter, qualifies, type PlayerSample } from './meter'
export type PlayerState = {
  sessionId: string | null
  version: number
  title: string
  tracks: QueueTrack[]
  sample: PlayerSample
  busy: boolean
  error: string
  preferences: PlaybackPreferences | null
}
export class PlaybackController {
  private state: PlayerState = {
    sessionId: null,
    version: 0,
    title: '',
    tracks: [],
    sample: { index: null, positionMs: 0, status: 'stopped' },
    busy: false,
    error: '',
    preferences: null,
  }
  private listeners = new Set<() => void>()
  private meter = new ListeningMeter((e) => this.record(e))
  private startFailed = false
  private lifecycle = 0
  private playbackId = ''
  private sequence = 0
  private generation = 0
  private disposed = false
  private pending: PlaybackObservation[] = []
  private sending = false
  private unsubscribe: (() => void) | undefined
  private clearRequest: { id: string; revision: number } | null = null
  private retryTimer: ReturnType<typeof setTimeout> | undefined
  private key: string
  constructor(
    private api: MixtapeApi,
    private music: MusicKitClient,
    owner: string,
  ) {
    this.key = `mixtape.playback.${owner}`
  }
  getState = () => this.state
  subscribe = (fn: () => void) => {
    this.listeners.add(fn)
    return () => {
      this.listeners.delete(fn)
    }
  }
  private update(p: Partial<PlayerState>) {
    if (this.disposed) return
    this.state = { ...this.state, ...p }
    this.listeners.forEach((fn) => fn())
  }
  async initialize() {
    this.disposed = false
    const lifecycle = ++this.lifecycle
    try {
      const preferences = await this.api.playbackPreferences()
      if (this.disposed || lifecycle !== this.lifecycle) return
      this.update({ preferences })
      try {
        const stored = JSON.parse(localStorage.getItem(this.key) ?? 'null')
        if (
          preferences.enabled &&
          stored?.revision === preferences.revision &&
          Array.isArray(stored.events)
        )
          this.pending = stored.events
            .filter(
              (e: PlaybackObservation) =>
                Date.parse(e.occurredAt) > Date.now() - 7 * 86400000,
            )
            .slice(-100)
      } catch {}
      this.persist()
      void this.flush()
    } catch {
      /* Playback remains available without collecting. */
    }
    if (this.disposed || lifecycle !== this.lifecycle) return
    this.unsubscribe = this.music.observe?.((sample) => {
      this.update({ sample })
      if (!this.state.busy && this.state.preferences?.enabled)
        this.meter.sample(sample, performance.now())
    })
  }
  private persist() {
    try {
      if (this.pending.length)
        localStorage.setItem(
          this.key,
          JSON.stringify({
            revision: this.state.preferences?.revision,
            events: this.pending,
          }),
        )
      else localStorage.removeItem(this.key)
    } catch {}
  }
  private record(e: {
    index: number
    observedMs: number
    kind: 'listen' | 'skip' | 'repeat'
  }) {
    const track = this.state.tracks[e.index]
    if (
      e.kind === 'skip' &&
      track &&
      qualifies('listen', e.observedMs, track.durationMs ?? 0)
    )
      e = { ...e, kind: 'listen' }
    if (
      !this.state.preferences?.enabled ||
      !track ||
      !qualifies(e.kind, e.observedMs, track.durationMs ?? 0)
    )
      return
    this.pending.push({
      playbackId: this.playbackId,
      sequence: this.sequence++,
      sessionId: this.state.sessionId!,
      version: this.state.version,
      position: track.position,
      trackId: track.trackId,
      source: 'apple_web',
      kind: e.kind,
      observedMs: e.observedMs,
      occurredAt: new Date().toISOString(),
    })
    this.pending = this.pending.slice(-100)
    this.persist()
    void this.flush()
  }
  private async flush() {
    if (
      this.sending ||
      this.disposed ||
      !this.state.preferences?.enabled ||
      !this.pending.length
    )
      return
    this.sending = true
    const events = this.pending.slice(0, 20)
    const revision = this.state.preferences.revision
    try {
      await this.api.sendPlaybackEvidence({ revision, events })
      if (!this.disposed && this.state.preferences?.revision === revision) {
        const ids = new Set(events.map((e) => `${e.playbackId}:${e.sequence}`))
        this.pending = this.pending.filter(
          (e) => !ids.has(`${e.playbackId}:${e.sequence}`),
        )
        this.persist()
      }
    } catch (error) {
      if (
        error instanceof ApiError &&
        [400, 404, 409, 401].includes(error.status)
      ) {
        this.pending = []
        this.persist()
        if (error.status === 409) {
          this.meter.reset()
          this.update({ preferences: null })
        }
      }
    } finally {
      this.sending = false
      if (!this.disposed && this.pending.length) {
        clearTimeout(this.retryTimer)
        this.retryTimer = setTimeout(() => void this.flush(), 30000)
      }
    }
  }
  async start(
    sessionId: string,
    version: number,
    title: string,
    tracks: QueueTrack[],
  ) {
    if (this.state.busy) return false
    this.meter.finish('listen')
    this.startFailed = false
    const generation = ++this.generation
    this.playbackId = crypto.randomUUID()
    this.sequence = 0
    const playable = tracks.filter((t) => t.appleId).map((t) => ({ ...t }))
    this.update({
      sessionId,
      version,
      title,
      tracks: playable,
      busy: true,
      error: '',
      sample: { index: null, positionMs: 0, status: 'waiting' },
    })
    try {
      if (this.music.stop) await this.music.stop()
      if (generation !== this.generation) return false
      await this.music.play(playable.map((t) => t.appleId!))
      if (generation === this.generation && !this.music.observe)
        this.update({ sample: { index: 0, positionMs: 0, status: 'playing' } })
      return generation === this.generation
    } catch {
      if (generation === this.generation) this.startFailed = true
      if (generation === this.generation)
        this.update({
          error: 'Apple Music could not play this song. Your mix is unchanged.',
        })
      return false
    } finally {
      if (generation === this.generation) this.update({ busy: false })
    }
  }
  async command(
    kind: 'pause' | 'resume' | 'next' | 'previous' | 'repeat',
    seconds?: number,
  ) {
    if (this.state.busy) return
    if ((kind === 'next' || kind === 'resume') && this.startFailed) {
      await this.start(
        this.state.sessionId!,
        this.state.version,
        this.state.title,
        kind === 'next'
          ? this.state.tracks.slice((this.state.sample.index ?? 0) + 1)
          : this.state.tracks,
      )
      return
    }
    if (this.startFailed) return
    this.update({ busy: true, error: '' })
    try {
      if (kind === 'next') this.meter.intent = 'skip'
      if (kind === 'repeat') this.meter.intent = 'repeat'
      if (seconds !== undefined) {
        this.meter.seek()
        await this.music.seek?.(seconds)
      } else if (kind === 'repeat') {
        await this.music.seek?.(0)
        await this.music.resume?.()
      } else if (kind === 'pause') {
        await this.music.pause()
        this.update({ sample: { ...this.state.sample, status: 'paused' } })
      } else if (kind === 'resume') {
        if (this.music.resume) await this.music.resume()
        else await this.music.play(this.state.tracks.map((t) => t.appleId!))
        if (!this.music.observe)
          this.update({ sample: { ...this.state.sample, status: 'playing' } })
      } else {
        if (!this.music[kind]) throw new Error('Unavailable')
        await this.music[kind]!()
      }
    } catch {
      this.meter.intent = null
      this.update({
        error: 'Playback was interrupted. Try again when you are ready.',
      })
    } finally {
      this.update({ busy: false })
    }
  }
  async reconnect() {
    if (this.state.busy || !this.state.sessionId) return
    const generation = ++this.generation
    this.update({ busy: true, error: '' })
    try {
      await this.music.connect()
      if (this.disposed || generation !== this.generation) return
      this.update({ busy: false })
      await this.start(
        this.state.sessionId,
        this.state.version,
        this.state.title,
        this.state.tracks,
      )
    } catch {
      if (generation === this.generation)
        this.update({
          error: 'Apple Music access was not granted. Your mix is unchanged.',
        })
    } finally {
      if (generation === this.generation) this.update({ busy: false })
    }
  }
  async stop() {
    if (this.state.busy) this.startFailed = true
    ++this.generation
    this.meter.finish('listen')
    this.update({
      busy: false,
      sample: { ...this.state.sample, status: 'stopped' },
    })
    try {
      await this.music.stop?.()
    } catch {
      this.update({ error: 'Could not stop playback. Try again.' })
    }
  }
  async preference(enabled: boolean) {
    this.meter.reset()
    this.pending = []
    this.persist()
    this.update({ preferences: null })
    const preferences = await this.api.savePlaybackPreference(enabled)
    this.update({ preferences })
    return preferences
  }
  async clear(requestId: string) {
    if (this.clearRequest?.id !== requestId) {
      const prefs =
        this.state.preferences ?? (await this.api.playbackPreferences())
      this.clearRequest = { id: requestId, revision: prefs.revision }
    }
    this.meter.reset()
    this.pending = []
    this.persist()
    this.update({ preferences: null })
    try {
      const preferences = await this.api.clearPlaybackEvidence(
        requestId,
        this.clearRequest.revision,
      )
      this.update({ preferences })
      this.clearRequest = null
    } catch (error) {
      if (error instanceof ApiError && error.status === 409) {
        this.clearRequest = null
        const preferences = await this.api.playbackPreferences()
        this.update({ preferences })
      }
      throw error
    }
  }
  dispose() {
    this.disposed = true
    ++this.generation
    this.meter.reset()
    this.unsubscribe?.()
    clearTimeout(this.retryTimer)
    this.pending = []
    this.persist()
    void this.music.stop?.().catch(() => {})
    this.listeners.clear()
  }
}

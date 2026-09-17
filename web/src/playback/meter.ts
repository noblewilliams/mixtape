export type PlayerSample = {
  index: number | null
  positionMs: number
  status: 'playing' | 'paused' | 'waiting' | 'stopped'
}
export type ListeningKind = 'listen' | 'skip' | 'repeat'
export class ListeningMeter {
  private index: number | null = null
  private previous: { sample: PlayerSample; time: number } | null = null
  private observedMs = 0
  intent: ListeningKind | null = null
  constructor(
    private emit: (event: {
      index: number
      observedMs: number
      kind: ListeningKind
    }) => void,
  ) {}
  sample(sample: PlayerSample, time: number) {
    if (sample.index !== this.index) {
      this.finish(this.intent ?? 'listen')
      if (sample.status === 'playing') this.index = sample.index
    }
    if (this.index === null && sample.status === 'playing')
      this.index = sample.index
    const previous = this.previous
    if (
      previous &&
      sample.index === this.index &&
      previous.sample.index === sample.index
    ) {
      const elapsed = time - previous.time,
        progress = sample.positionMs - previous.sample.positionMs
      if (this.intent === 'repeat' && progress < -1000) {
        this.finish('repeat')
        this.index = sample.index
      } else if (
        sample.status === 'playing' &&
        previous.sample.status === 'playing' &&
        elapsed > 0 &&
        elapsed <= 2500 &&
        progress >= 0 &&
        Math.abs(progress - elapsed) <= 750
      )
        this.observedMs += Math.min(elapsed, progress)
    }
    this.previous = { sample, time }
    if (sample.status === 'stopped') this.finish(this.intent ?? 'listen')
  }
  seek() {
    this.previous = null
    this.intent = null
  }
  finish(kind: ListeningKind) {
    if (this.index !== null)
      this.emit({
        index: this.index,
        observedMs: Math.round(this.observedMs),
        kind,
      })
    this.index = null
    this.observedMs = 0
    this.previous = null
    this.intent = null
  }
  reset() {
    this.index = null
    this.observedMs = 0
    this.previous = null
    this.intent = null
  }
}
export function qualifies(
  kind: ListeningKind,
  observed: number,
  duration: number,
) {
  if (!duration || observed > duration + 2000) return false
  return kind === 'skip'
    ? observed >= 3000 && observed < Math.min(30000, duration * 0.25)
    : kind === 'repeat'
      ? observed >= 30000
      : observed >= Math.max(10000, Math.min(60000, duration * 0.8))
}

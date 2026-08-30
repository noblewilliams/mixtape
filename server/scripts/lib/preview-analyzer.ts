/**
 * preview-analyzer — local audio analysis core for the P2.5 feature-coverage
 * lift (see docs/superpowers/plans/2026-08-30-p2.5-local-preview-analysis.md).
 *
 * Runs ONLY from founder-Mac CLI scripts (never bundled into the Worker):
 *   decodeToWav(m4aPath, wavPath)  — afconvert child_process wrapper
 *   analyzePreview(wavPath)        — essentia.js feature extraction
 *
 * Nothing under src/ may import this module — wrangler must never see it.
 *
 * Spike outcome (Task 1, ~10 min, well under the 20-min timebox): essentia.js's
 * Node/UMD build works directly and synchronously via `createRequire` — no
 * async WASM loader dance needed (the "EssentiaWASM()" factory pattern from
 * the browser docs does NOT apply here: `EssentiaWASM` from the UMD build is
 * already an instantiated Emscripten module object, and `new Essentia(EssentiaWASM)`
 * "just works" the moment the package is required). The librosa/python3 fallback
 * documented in the plan was NOT needed.
 *
 * Honesty rule (binding, see plan): only tempo/key/mode/energy/danceability/
 * loudness are derivable from 30s of audio — valence/acousticness/
 * instrumentalness/liveness/speechiness are intentionally NOT emitted here.
 */
import { execFile } from 'node:child_process'
import { promises as fs } from 'node:fs'
import { createRequire } from 'node:module'
import { resolve as resolvePath } from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)
const require = createRequire(import.meta.url)

export type PreviewFeatures = {
  tempo: number
  key: number
  mode: 0 | 1
  energy: number
  danceability: number
  loudness: number
}

// Standard pitch-class numbering (C=0 .. B=11), matching the convention
// ReccoBeats/Spotify-style `key` columns already use (src/enrich/reccobeats.ts
// passes these straight through as bare numbers).
const PITCH_CLASS: Record<string, number> = {
  C: 0,
  'C#': 1,
  Db: 1,
  D: 2,
  'D#': 3,
  Eb: 3,
  E: 4,
  F: 5,
  'F#': 6,
  Gb: 6,
  G: 7,
  'G#': 8,
  Ab: 8,
  A: 9,
  'A#': 10,
  Bb: 10,
  B: 11,
}

/**
 * Maps essentia's KeyExtractor pitch-class name to our 0-11 numbering.
 * Throws a fixed-string error on an unrecognized name rather than silently
 * coercing it to C=0 — a garbled key must fail loudly (and become
 * analysis_failed/retryable) rather than masquerade as a real analyzed value
 * (fabrication rule, see plan).
 */
export function pitchClassOf(name: string): number {
  const pc = PITCH_CLASS[name]
  if (pc === undefined) throw new Error('unrecognized key name from essentia')
  return pc
}

/** True when the stock macOS `afconvert` binary is on PATH. */
export async function isAfconvertAvailable(): Promise<boolean> {
  try {
    await execFileAsync('which', ['afconvert'])
    return true
  } catch {
    return false
  }
}

/**
 * Decode any afconvert-readable audio file (we use it for m4a previews) to
 * mono 16-bit LE PCM WAV at 44.1kHz — the format essentia.js/node-wav expect.
 *
 * Errors are intentionally a fixed string: afconvert's stderr can echo back
 * filesystem paths and other environment detail we don't want flowing into
 * logs (same lesson as the credential-leak guard in scripts/retitle-sessions.ts).
 */
export async function decodeToWav(inputPath: string, outPath: string): Promise<void> {
  // path.resolve() before handing paths to execFile: a caller-supplied
  // filename starting with "-" (e.g. from an untrusted download name) would
  // otherwise be parsed by afconvert as a flag rather than a path. Resolving
  // against cwd first means the argument afconvert sees never starts with
  // "-".
  const resolvedIn = resolvePath(inputPath)
  const resolvedOut = resolvePath(outPath)
  try {
    await execFileAsync(
      'afconvert',
      ['-f', 'WAVE', '-d', 'LEI16@44100', '-c', '1', resolvedIn, resolvedOut],
      { timeout: 30_000, maxBuffer: 10 * 1024 * 1024 },
    )
  } catch {
    // afconvert can leave a truncated file behind when it dies partway
    // through encoding (or times out) — clean it up so a caller never
    // mistakes a partial write for a successful decode.
    await fs.unlink(resolvedOut).catch(() => {})
    throw new Error('afconvert failed')
  }
}

// essentia.js's Node/UMD build self-instantiates its WASM module the moment
// it's required (see file header) — load + construct once and reuse across
// calls in the same process (the orchestrator in Task 3 will call
// analyzePreview() once per track, potentially thousands of times).
let essentiaSingleton: EssentiaInstance | null = null

type EssentiaVector = { delete(): void }

type EssentiaInstance = {
  arrayToVector(arr: Float32Array): EssentiaVector
  RhythmExtractor2013(
    signal: EssentiaVector,
    maxTempo: number,
    method: string,
    minTempo: number,
  ): {
    bpm: number
    confidence: number
    ticks: EssentiaVector
    estimates: EssentiaVector
    bpmIntervals: EssentiaVector
  }
  KeyExtractor(signal: EssentiaVector): { key: string; scale: string }
  RMS(signal: EssentiaVector): { rms: number }
  Danceability(signal: EssentiaVector): { danceability: number; dfa: EssentiaVector }
}

function loadEssentia(): EssentiaInstance {
  if (essentiaSingleton) return essentiaSingleton
  const { EssentiaWASM, Essentia } = require('essentia.js')
  essentiaSingleton = new Essentia(EssentiaWASM) as EssentiaInstance
  return essentiaSingleton
}

/** True when the essentia.js analysis runtime can be loaded in this process. */
export function isAnalyzerAvailable(): boolean {
  try {
    loadEssentia()
    return true
  } catch {
    return false
  }
}

function clamp01(x: number): number {
  if (!Number.isFinite(x)) return 0
  return Math.min(1, Math.max(0, x))
}

function clampDb(x: number): number {
  if (!Number.isFinite(x)) return -60
  return Math.min(0, Math.max(-60, x))
}

// Below this RMS, essentia's extractors are operating on effective silence:
// RhythmExtractor2013 fabricates a plausible-looking-but-meaningless tempo
// (probed live: silence yields a raw 738 BPM, octave-collapsed by 'degara'
// itself down to 92 — a confident-looking number with no basis in the
// audio). We gate on it before running any extractor rather than let a
// fabricated value flow through.
const RMS_FLOOR = 1e-4
const MIN_TEMPO = 40
const MAX_TEMPO = 250
const DEGENERATE_AUDIO_ERROR = 'degenerate audio — no analysis'

/**
 * Extract the honesty-rule-approved feature subset from a decoded WAV file.
 * Deterministic for a given file (essentia.js's algorithms are not seeded
 * with anything time- or randomness-dependent).
 */
export async function analyzePreview(wavPath: string): Promise<PreviewFeatures> {
  const essentia = loadEssentia()
  const nodeWav = require('node-wav') as {
    decode(buf: Buffer): { sampleRate: number; channelData: Float32Array[] }
  }

  const buf = await fs.readFile(wavPath)
  const decoded = nodeWav.decode(buf)
  const samples = decoded.channelData[0]
  if (!samples || samples.length === 0) {
    throw new Error('empty audio decoded from wav')
  }
  // Every extractor below assumes 44.1kHz mono input — RhythmExtractor2013's
  // tempo math in particular is directly tied to sample rate, so a 48kHz
  // input would silently skew the reported tempo by ~8.8% rather than fail.
  // decodeToWav always produces 44.1kHz, so this only trips on a
  // hand-supplied or malformed wav.
  if (decoded.sampleRate !== 44100) {
    throw new Error('unsupported sample rate — expected 44100Hz mono wav')
  }

  const signal = essentia.arrayToVector(samples)
  let rhythm: ReturnType<EssentiaInstance['RhythmExtractor2013']> | null = null
  let dance: ReturnType<EssentiaInstance['Danceability']> | null = null
  try {
    const rms = essentia.RMS(signal).rms
    if (rms < RMS_FLOOR) throw new Error(DEGENERATE_AUDIO_ERROR)

    // Explicit method + fixed tempo bounds: 'degara' is a single
    // deterministic beat tracker, chosen for simplicity and verified
    // determinism across repeated and interleaved calls on a shared
    // Essentia instance (see the interleaved-call determinism test) — not
    // because the default 'multifeature' ensemble method was proven
    // non-deterministic.
    rhythm = essentia.RhythmExtractor2013(signal, 208, 'degara', 40)
    const rawBpm = rhythm.bpm
    if (!Number.isFinite(rawBpm) || rawBpm < MIN_TEMPO || rawBpm > MAX_TEMPO) {
      throw new Error(DEGENERATE_AUDIO_ERROR)
    }
    // 'degara' already collapses octave errors internally (probed live: it
    // never corrected a genuine tempo estimate, only laundered a
    // silence-artifact 738 BPM down to a plausible-looking 92) — we report
    // its output as-is rather than re-fold it. A true ~190 BPM track may
    // therefore read ~95: a known estimator limitation, not something we
    // launder on top of, and folding again would also confine every
    // analyzed tempo into a narrow perceptual band, breaking
    // mixed-source comparability.
    const tempo = rawBpm

    const keyResult = essentia.KeyExtractor(signal)
    const key = pitchClassOf(keyResult.key)
    const mode: 0 | 1 = keyResult.scale === 'major' ? 1 : 0

    const rmsDbfs = 20 * Math.log10(rms)

    // Calibrated against real mastered-music loudness (roughly -30 to -5
    // dBFS RMS) rather than raw [0,1] RMS, which compresses real tracks into
    // the bottom third of the range and would read the whole analyzed
    // cohort as uniformly low-energy to the curation LLM. -30 dBFS -> 0,
    // -5 dBFS -> 1. (Calibration window; docs/decisions.md entry lands in
    // Task 4 per plan.)
    const energy = clamp01((rmsDbfs - -30) / (-5 - -30))

    dance = essentia.Danceability(signal)
    // Danceability's DFA-derived output isn't natively bounded — Essentia's
    // docs describe a typical real-music range of roughly 0-3 — so we scale
    // linearly against that ceiling and clamp, rather than write an
    // unbounded value into a [0,1] column (ReccoBeats-comparability
    // requirement from the plan).
    const danceability = clamp01(dance.danceability / 3)

    // Loudness is a dBFS approximation (NOT true ReplayGain/EBU R128
    // perceptual loudness): ReplayGain returns gain-to-APPLY, which is
    // negative for loud audio and positive for quiet audio — the inverse of
    // what a "loudness" column should read — and its internal reference
    // blows up to large positive values on near-silent input. We drop it
    // entirely and report a straightforward dBFS reading of the signal's
    // RMS instead, clamped to a plausible loudness range.
    const loudness = clampDb(rmsDbfs)

    return { tempo, key, mode, energy, danceability, loudness }
  } finally {
    // Embind vectors live on the WASM heap and are not garbage-collected by
    // V8 — free explicitly so a long-running batch (Task 3) doesn't leak.
    signal.delete()
    rhythm?.ticks.delete()
    rhythm?.estimates.delete()
    rhythm?.bpmIntervals.delete()
    dance?.dfa.delete()
  }
}

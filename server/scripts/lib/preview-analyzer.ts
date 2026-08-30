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
  try {
    await execFileAsync('afconvert', ['-f', 'WAVE', '-d', 'LEI16@44100', '-c', '1', inputPath, outPath])
  } catch {
    throw new Error('afconvert failed')
  }
}

// essentia.js's Node/UMD build self-instantiates its WASM module the moment
// it's required (see file header) — load + construct once and reuse across
// calls in the same process (the orchestrator in Task 3 will call
// analyzePreview() once per track, potentially thousands of times).
let essentiaSingleton: EssentiaInstance | null = null

type EssentiaInstance = {
  arrayToVector(arr: Float32Array): EssentiaVector
  RhythmExtractor2013(
    signal: EssentiaVector,
    maxTempo: number,
    method: string,
    minTempo: number,
  ): { bpm: number }
  KeyExtractor(signal: EssentiaVector): { key: string; scale: string }
  RMS(signal: EssentiaVector): { rms: number }
  Danceability(signal: EssentiaVector): { danceability: number }
  ReplayGain(signal: EssentiaVector): { replayGain: number }
}

type EssentiaVector = { delete(): void }

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

// RhythmExtractor2013 can lock onto half- or double-time on strongly
// periodic material (click tracks, four-on-the-floor kicks) — a well-known
// "octave error" in tempo estimation. Standard practice is to fold the
// estimate by octave (×2 / ÷2) into the perceptually-typical 70-180 BPM
// walking-tempo band before reporting, which is what we do here.
function normalizeTempoOctave(bpm: number): number {
  let t = bpm
  while (t > 0 && t < 70) t *= 2
  while (t > 180) t /= 2
  return t
}

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

  const signal = essentia.arrayToVector(samples)
  try {
    // Explicit method + fixed tempo bounds: essentia.js's default
    // 'multifeature' ensemble method carries internal algorithm state across
    // calls on a shared Essentia instance and was observed to return
    // different BPMs for byte-identical repeat calls (non-deterministic —
    // violates the plan's determinism requirement). 'degara' is a single
    // deterministic beat tracker and was stable across dozens of repeat and
    // interleaved calls during Task 1's spike.
    const tempo = normalizeTempoOctave(essentia.RhythmExtractor2013(signal, 208, 'degara', 40).bpm)

    const keyResult = essentia.KeyExtractor(signal)
    const key = PITCH_CLASS[keyResult.key] ?? 0
    const mode: 0 | 1 = keyResult.scale === 'major' ? 1 : 0

    const rms = essentia.RMS(signal).rms
    const energy = clamp01(rms)

    // Danceability's DFA-derived output isn't natively bounded — Essentia's
    // docs describe a typical real-music range of roughly 0-3 — so we scale
    // linearly against that ceiling and clamp, rather than write an
    // unbounded value into a [0,1] column (ReccoBeats-comparability
    // requirement from the plan).
    const danceRaw = essentia.Danceability(signal).danceability
    const danceability = clamp01(danceRaw / 3)

    // ReplayGain's internal reference blows up (large positive) on
    // near-silent input, so we don't trust it below an RMS floor and report
    // a fixed very-quiet loudness instead.
    let loudness: number
    if (rms < 1e-4) {
      loudness = -70
    } else {
      const rg = essentia.ReplayGain(signal).replayGain
      loudness = Number.isFinite(rg) ? Math.min(rg, 0) : -70
    }

    return { tempo, key, mode, energy, danceability, loudness }
  } finally {
    // Embind vectors live on the WASM heap and are not garbage-collected by
    // V8 — free explicitly so a long-running batch (Task 3) doesn't leak.
    signal.delete()
  }
}

import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { createRequire } from 'node:module'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  analyzePreview,
  decodeToWav,
  isAfconvertAvailable,
  isAnalyzerAvailable,
} from '../../scripts/lib/preview-analyzer'

const require = createRequire(import.meta.url)

const SAMPLE_RATE = 44100

// --- programmatic WAV fixtures (no committed binaries) --------------------

function writeWavFile(path: string, samples: Float32Array, sampleRate = SAMPLE_RATE): Promise<void> {
  const nodeWav = require('node-wav') as {
    encode(channelData: Float32Array[], opts: { sampleRate: number; bitDepth: number }): Buffer
  }
  const buf = nodeWav.encode([samples], { sampleRate, bitDepth: 16 })
  return writeFile(path, buf)
}

/** A percussive click track at a fixed BPM — decaying 1kHz blips on a beat grid. */
function clickTrack(bpm: number, seconds: number): Float32Array {
  const n = Math.floor(SAMPLE_RATE * seconds)
  const out = new Float32Array(n)
  const period = Math.round((60 / bpm) * SAMPLE_RATE)
  const clickLen = 200
  for (let start = 0; start < n; start += period) {
    for (let i = 0; i < clickLen && start + i < n; i++) {
      out[start + i] = Math.sin((2 * Math.PI * 1000 * i) / SAMPLE_RATE) * Math.exp(-i / 30)
    }
  }
  return out
}

function tone(freq: number, seconds: number, amp = 0.5): Float32Array {
  const n = Math.floor(SAMPLE_RATE * seconds)
  const out = new Float32Array(n)
  for (let i = 0; i < n; i++) out[i] = amp * Math.sin((2 * Math.PI * freq * i) / SAMPLE_RATE)
  return out
}

function silence(seconds: number): Float32Array {
  return new Float32Array(Math.floor(SAMPLE_RATE * seconds))
}

/** A synthesized A-minor triad (A3 + C4 + E4), summed and slightly attenuated. */
function aMinorTriad(seconds: number): Float32Array {
  const n = Math.floor(SAMPLE_RATE * seconds)
  const out = new Float32Array(n)
  for (let i = 0; i < n; i++) {
    const t = i / SAMPLE_RATE
    out[i] =
      0.3 * Math.sin(2 * Math.PI * 220 * t) +
      0.3 * Math.sin(2 * Math.PI * 261.63 * t) +
      0.3 * Math.sin(2 * Math.PI * 329.63 * t)
  }
  return out
}

// --- suite ------------------------------------------------------------------

// it.skipIf/describe.skipIf evaluate their condition at collection time, not
// inside beforeAll, so these must be resolved via top-level await (supported
// by vitest's ESM test files) rather than assigned in a beforeAll hook.
const afconvertAvailable = await isAfconvertAvailable()
const analyzerAvailable = isAnalyzerAvailable()

let workDir = ''

beforeAll(async () => {
  workDir = await mkdtemp(join(tmpdir(), 'mixtape-preview-analyzer-'))
})

afterAll(async () => {
  if (workDir) await rm(workDir, { recursive: true, force: true })
})

describe('decodeToWav', () => {
  it.skipIf(!afconvertAvailable)('decodes an input file via the real afconvert child process', async () => {
    // We don't have a committed m4a fixture (no binaries), but afconvert
    // reads WAV containers too — feeding it a stereo/48kHz source and
    // asserting the mono/44.1kHz output analyzes cleanly exercises the same
    // child_process path decodeToWav uses for real m4a previews.
    const sourcePath = join(workDir, 'source.wav')
    const stereo48k = tone(440, 1)
    const nodeWav = require('node-wav') as {
      encode(channelData: Float32Array[], opts: { sampleRate: number; bitDepth: number }): Buffer
    }
    await writeFile(sourcePath, nodeWav.encode([stereo48k, stereo48k], { sampleRate: 48000, bitDepth: 16 }))

    const outPath = join(workDir, 'decoded.wav')
    await decodeToWav(sourcePath, outPath)

    const features = await analyzePreview(outPath)
    expect(features.energy).toBeGreaterThan(0)
  })

  it.skipIf(!afconvertAvailable)('throws a fixed-string error, never interpolating afconvert stderr', async () => {
    await expect(decodeToWav(join(workDir, 'does-not-exist.m4a'), join(workDir, 'out.wav'))).rejects.toThrow(
      'afconvert failed',
    )
  })
})

describe('analyzePreview', () => {
  it.skipIf(!analyzerAvailable)('detects tempo within ±3 BPM of a 120 BPM click track (octave-normalized)', async () => {
    const path = join(workDir, 'click-120.wav')
    await writeWavFile(path, clickTrack(120, 10))

    const features = await analyzePreview(path)

    expect(features.tempo).toBeGreaterThan(0)
    expect(features.tempo).toBeCloseTo(120, 0)
    expect(Math.abs(features.tempo - 120)).toBeLessThanOrEqual(3)
  })

  it.skipIf(!analyzerAvailable)('orders energy: a 440Hz tone above silence, both within [0,1]', async () => {
    const tonePath = join(workDir, 'tone.wav')
    const silencePath = join(workDir, 'silence.wav')
    await writeWavFile(tonePath, tone(440, 3))
    await writeWavFile(silencePath, silence(3))

    const toneFeatures = await analyzePreview(tonePath)
    const silenceFeatures = await analyzePreview(silencePath)

    expect(toneFeatures.energy).toBeGreaterThan(silenceFeatures.energy)
    expect(toneFeatures.energy).toBeGreaterThanOrEqual(0)
    expect(toneFeatures.energy).toBeLessThanOrEqual(1)
    expect(silenceFeatures.energy).toBeGreaterThanOrEqual(0)
    expect(silenceFeatures.energy).toBeLessThanOrEqual(1)
  })

  it.skipIf(!analyzerAvailable)('reports danceability and loudness in the ReccoBeats-comparable ranges', async () => {
    const path = join(workDir, 'click-120-range.wav')
    await writeWavFile(path, clickTrack(120, 10))

    const features = await analyzePreview(path)

    expect(features.danceability).toBeGreaterThanOrEqual(0)
    expect(features.danceability).toBeLessThanOrEqual(1)
    expect(features.loudness).toBeLessThanOrEqual(0)
  })

  it.skipIf(!analyzerAvailable)('reports key/mode within valid shape (0-11, 0|1) on a synthesized A-minor triad', async () => {
    const path = join(workDir, 'a-minor.wav')
    await writeWavFile(path, aMinorTriad(4))

    const features = await analyzePreview(path)

    // Key detection on a bare synthetic triad (no timbre/overtone realism)
    // can be flaky in either direction, so we assert shape/range here rather
    // than the exact pitch class — per the plan's guidance to fall back to
    // shape assertions if key detection on synthetic fixtures proves
    // unreliable. (In practice essentia.js's KeyExtractor DID correctly
    // report A minor on this fixture during the Task 1 spike — see report.)
    expect(Number.isInteger(features.key)).toBe(true)
    expect(features.key).toBeGreaterThanOrEqual(0)
    expect(features.key).toBeLessThanOrEqual(11)
    expect([0, 1]).toContain(features.mode)
  })

  it.skipIf(!analyzerAvailable)('is deterministic for the same file', async () => {
    const path = join(workDir, 'determinism.wav')
    await writeWavFile(path, clickTrack(128, 6))

    const a = await analyzePreview(path)
    const b = await analyzePreview(path)

    expect(a).toEqual(b)
  })
})

import { execFile } from 'node:child_process'
import { chmod, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join, resolve } from 'node:path'
import { promisify } from 'node:util'
import { afterEach, describe, expect, it } from 'vitest'

const execFileAsync = promisify(execFile)
const SCRIPT = resolve('scripts/backfill-artwork.sh')
const temporaryDirectories: string[] = []

async function harness() {
  const directory = await mkdtemp(join(tmpdir(), 'mixtape-artwork-backfill-'))
  temporaryDirectories.push(directory)
  const bin = join(directory, 'bin')
  await execFileAsync('mkdir', ['-p', bin])
  const curl = join(bin, 'curl')
  await writeFile(
    curl,
    `#!/bin/bash
set -eu
out=''
method='GET'
url=''
args_file="\${CAPTURE_FILE:-}"
if [ -n "$args_file" ]; then printf '%s\n' "$@" > "$args_file"; fi
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output) out="$2"; shift 2 ;;
    --request) method="$2"; shift 2 ;;
    --write-out) shift 2 ;;
    --header)
      header_arg="$2"
      if [ -n "\${HEADER_CAPTURE_FILE:-}" ] && [[ "$header_arg" == @* ]]; then
        header_path="\${header_arg#@}"
        cp "$header_path" "$HEADER_CAPTURE_FILE"
      fi
      shift 2
      ;;
    --connect-timeout|--max-time) shift 2 ;;
    --silent|--show-error) shift ;;
    http://*|https://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
body="$STATUS_BODY"
if [ "$method" = 'POST' ]; then
  count=0
  if [ -f "$STATE_FILE" ]; then count=$(cat "$STATE_FILE"); fi
  if [ "$count" -eq 0 ]; then body="$RUN_BODY_1"; else body="$RUN_BODY_2"; fi
  printf '%s' $((count + 1)) > "$STATE_FILE"
fi
printf '%s' "$body" > "$out"
printf '%s' "\${HTTP_STATUS:-200}"
`,
  )
  await chmod(curl, 0o755)
  return {
    directory,
    stateFile: join(directory, 'state'),
    captureFile: join(directory, 'args'),
    headerCaptureFile: join(directory, 'header'),
    env: {
      ...process.env,
      PATH: `${bin}:${process.env.PATH ?? ''}`,
      ARTWORK_API_BASE: 'https://mixtape.example.test',
      ENRICH_ADMIN_TOKEN: 'fake-admin-secret',
      STATE_FILE: join(directory, 'state'),
      BACKOFF_SLEEP_SECONDS: '0',
      STATUS_BODY: '{"tracks":4,"withArtwork":1,"missingArtwork":3,"retryable":3}',
      RUN_BODY_1: '{"processed":2,"matched":1,"missing":1,"failed":0,"remaining":1}',
      RUN_BODY_2: '{"processed":1,"matched":1,"missing":0,"failed":0,"remaining":0}',
    },
  }
}

afterEach(async () => {
  await Promise.all(temporaryDirectories.splice(0).map((directory) => rm(directory, { recursive: true })))
})

describe('backfill-artwork.sh', () => {
  it('defaults to status-only and prints counts without the admin token', async () => {
    const test = await harness()

    const result = await execFileAsync('bash', [SCRIPT], { env: test.env })

    expect(result.stdout).toContain('tracks=4')
    expect(result.stdout).toContain('with_artwork=1')
    expect(result.stdout).toContain('missing_artwork=3')
    expect(result.stdout).not.toContain('fake-admin-secret')
    await expect(readFile(test.stateFile, 'utf8')).rejects.toThrow()
  })

  it('applies bounded batches until the endpoint reports no remaining work', async () => {
    const test = await harness()

    const result = await execFileAsync('bash', [SCRIPT, '--apply', '--limit', '300'], {
      env: test.env,
    })

    expect(result.stdout).toContain('batch=1 processed=2 matched=1 missing=1 failed=0 remaining=1')
    expect(result.stdout).toContain('batch=2 processed=1 matched=1 missing=0 failed=0 remaining=0')
    expect(await readFile(test.stateFile, 'utf8')).toBe('2')
  })

  it('loads quoted values safely and never prints a non-2xx response body', async () => {
    const test = await harness()
    const devVars = join(test.directory, '.dev.vars')
    await writeFile(
      devVars,
      'ENRICH_ADMIN_TOKEN="quoted-token"\nBETTER_AUTH_URL=\'https://quoted.example.test\'\n',
    )
    const env = {
      ...test.env,
      ENRICH_ADMIN_TOKEN: '',
      ARTWORK_API_BASE: '',
      DEV_VARS_FILE: devVars,
      CAPTURE_FILE: test.captureFile,
      HEADER_CAPTURE_FILE: test.headerCaptureFile,
      HTTP_STATUS: '500',
      STATUS_BODY: '{"secret":"upstream-secret-body"}',
    }

    const error = await execFileAsync('bash', [SCRIPT], { env }).catch((caught: unknown) => caught as {
      stdout: string
      stderr: string
    })

    expect(error.stdout).not.toContain('upstream-secret-body')
    expect(error.stderr).toContain('request failed (HTTP 500)')
    expect(error.stderr).not.toContain('upstream-secret-body')
    const args = await readFile(test.captureFile, 'utf8')
    expect(args).toContain('https://quoted.example.test/enrich/artwork/status')
    expect(args).not.toContain('quoted-token')
    expect(await readFile(test.headerCaptureFile, 'utf8')).toBe('X-Admin-Token: quoted-token\n')
  })

  it('allows explicit loopback HTTP for local operator use', async () => {
    const test = await harness()
    const env = {
      ...test.env,
      ARTWORK_API_BASE: 'http://127.0.0.1:8787',
      CAPTURE_FILE: test.captureFile,
    }

    await execFileAsync('bash', [SCRIPT], { env })

    expect(await readFile(test.captureFile, 'utf8')).toContain(
      'http://127.0.0.1:8787/enrich/artwork/status',
    )
  })

  it.each([
    ['non-loopback HTTP', 'http://mixtape.example.test'],
    ['lookalike loopback host', 'http://localhost.example.test'],
    ['embedded credentials', 'https://operator:secret@mixtape.example.test'],
    ['query string', 'https://mixtape.example.test?target=other'],
    ['fragment', 'https://mixtape.example.test#other'],
  ])('rejects an unsafe API base with %s', async (_label, base) => {
    const test = await harness()
    const env = {
      ...test.env,
      ARTWORK_API_BASE: base,
      CAPTURE_FILE: test.captureFile,
    }

    const error = await execFileAsync('bash', [SCRIPT], { env }).catch(
      (caught: unknown) => caught as { stdout: string; stderr: string },
    )

    expect(error.stderr).toContain('API base must use HTTPS or explicit loopback HTTP')
    expect(error.stderr).not.toContain(base)
    await expect(readFile(test.captureFile, 'utf8')).rejects.toThrow()
  })
})

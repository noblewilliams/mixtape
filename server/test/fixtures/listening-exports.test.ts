import { spawnSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { describe, expect, it } from 'vitest'

// The listening-export fixture suite (fixtures/listening-exports) is the
// contract the web and iOS parsers are tested against. This is its gate in
// the authoritative test run: the committed archives and expected files must
// match a fresh build of the case definitions, and the suite's own
// self-checks (verify.test.mjs) must pass.
const REPO_ROOT = fileURLToPath(new URL('../../../', import.meta.url))
const SUITE = 'fixtures/listening-exports'

function runNode(args: string[]) {
  const result = spawnSync(process.execPath, args, { cwd: REPO_ROOT, encoding: 'utf8', timeout: 120_000 })
  return { status: result.status, output: `${result.stdout}${result.stderr}` }
}

describe('listening-export fixtures', () => {
  it('build.mjs --check: committed archives and expected files match a fresh build', () => {
    const { status, output } = runNode([`${SUITE}/build.mjs`, '--check'])
    expect(status, output).toBe(0)
    expect(output).toContain('up to date')
  }, 120_000)

  it('verify.test.mjs: the suite passes its own self-checks', () => {
    const { status, output } = runNode(['--test', `${SUITE}/verify.test.mjs`])
    expect(status, output).toBe(0)
  }, 120_000)
})

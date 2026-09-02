import { describe, expect, it } from 'vitest'
import { canonicalize, canonicalJson } from './canonical'
import { inspectExport, parseExport, UnreadableExportError } from './spotify-parser'
import { openZipArchive } from './zip-reader'
import { listFixtureCases, readExpected, readFixtureArchive } from '../test/listening-export-fixtures'

const cases = listFixtureCases()

describe('listening-export fixture suite', () => {
  it('finds the committed fixture cases', () => {
    expect(cases.length).toBeGreaterThanOrEqual(13)
    expect(cases.map((fixture) => fixture.name)).toContain('extended-basic')
    expect(cases.map((fixture) => fixture.name)).toContain('account-pii-present')
  })

  for (const fixture of cases) {
    describe(fixture.name, () => {
      for (const option of fixture.options) {
        const expected = readExpected(fixture.name, option.name)

        if (expected.error !== undefined) {
          it(`${option.name}: fails closed on ${expected.error.file ?? 'no allow-listed file'}`, async () => {
            const archive = await openZipArchive(readFixtureArchive(fixture.name))
            const failure = await parseExport(archive, {
              timeZone: option.timeZone,
              includePrivateSessions: option.includePrivateSessions,
            }).then(
              () => null,
              (error: unknown) => error,
            )
            expect(failure).toBeInstanceOf(UnreadableExportError)
            const unreadable = failure as UnreadableExportError
            expect(unreadable.file).toBe(expected.error?.file)
            expect(unreadable.inventory).toEqual(expected.inventory)
            expect(await inspectExport(archive)).toEqual(expected.inventory)
          })
          continue
        }

        it(`${option.name}: parses to the expected snapshot and inventory`, async () => {
          const archive = await openZipArchive(readFixtureArchive(fixture.name))
          const { inventory, snapshot } = await parseExport(archive, {
            timeZone: option.timeZone,
            includePrivateSessions: option.includePrivateSessions,
          })
          expect(inventory).toEqual(expected.inventory)
          expect(canonicalize(snapshot)).toEqual(expected.snapshot)
          // Byte-identical canonical JSON: the expected file is the builder's
          // JSON.stringify(document, null, 2), so the snapshot's text is the
          // same key order, sort order, and two-space print.
          expect(canonicalJson(snapshot)).toBe(`${JSON.stringify(expected.snapshot, null, 2)}\n`)
          expect(await inspectExport(archive)).toEqual(expected.inventory)
        })
      }
    })
  }
})

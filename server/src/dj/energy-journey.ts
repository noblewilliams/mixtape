export type EnergyArc = 'rise' | 'fall' | 'arc' | 'steady'
export type EnergyJourney = {
  status: 'limited' | 'follows' | 'mixed'
  known: number
  total: number
  bands: [number, number, number] | null
}
const valid = (value: number | null): value is number =>
  value !== null && Number.isFinite(value) && value >= 0 && value <= 1

// An assessment of the committed order, never a sorting pass. Hard choices and
// pins remain intact. Require two known tracks and 2/3 coverage in every third.
export function evaluateEnergyJourney(
  arc: EnergyArc,
  energies: (number | null)[],
): EnergyJourney {
  const result: EnergyJourney = {
    status: 'limited',
    known: energies.filter(valid).length,
    total: energies.length,
    bands: null,
  }
  const bands: number[] = []
  for (let third = 0; third < 3; third++) {
    const group = energies.slice(
      Math.floor((third * energies.length) / 3),
      Math.floor(((third + 1) * energies.length) / 3),
    )
    const known = group.filter(valid)
    if (known.length < 2 || known.length / group.length < 2 / 3) return result
    bands.push(known.reduce((a, b) => a + b, 0) / known.length)
  }
  const [start, middle, end] = bands
  // Coarse tolerances avoid claiming small measurement differences are audible.
  const follows =
    arc === 'steady'
      ? Math.max(...bands) - Math.min(...bands) <= 0.12
      : arc === 'rise'
        ? end - start >= 0.15 && middle >= start - 0.05 && end >= middle - 0.05
        : arc === 'fall'
          ? start - end >= 0.15 &&
            middle <= start + 0.05 &&
            end <= middle + 0.05
          : middle - start >= 0.15 && middle - end >= 0.15
  return {
    ...result,
    status: follows ? 'follows' : 'mixed',
    bands: bands as [number, number, number],
  }
}

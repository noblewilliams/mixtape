import { defineConfig } from 'vitest/config'

export default defineConfig({
  test: {
    // Every suite spins up its own PGlite instance from a dumped template.
    // Under parallel file execution that WASM work contends for CPU, so a
    // cold suite can blow past the 5s default even though nothing is wrong.
    // These ceilings only bound genuine hangs — healthy runs finish in ~10s.
    testTimeout: 20000,
    hookTimeout: 20000,
  },
})

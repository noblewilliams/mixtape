// Day labels use the device zone; pin the suite to UTC so they are
// deterministic on every machine. Node re-reads TZ on assignment.
process.env.TZ = 'UTC'

import '@testing-library/jest-dom/vitest'

class ResizeObserverStub {
  observe() {}
  unobserve() {}
  disconnect() {}
}

window.ResizeObserver = ResizeObserverStub

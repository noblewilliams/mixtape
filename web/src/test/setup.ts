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

// Shared drafts (useSharedRestorableState) live for the page; each test starts clean.
import { afterEach } from 'vitest'
import { cleanup } from '@testing-library/react'
import { clearWorkspaceRestore } from '../lib/workspace-restore'
afterEach(() => { cleanup(); clearWorkspaceRestore() })

import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it } from 'vitest'
import { clearWorkspaceRestore, useRestorableState, WorkspaceRestoreProvider } from './workspace-restore'

afterEach(() => { cleanup(); clearWorkspaceRestore() })
function Page() {
  const [title, setTitle] = useRestorableState('test.title', 'Default')
  return <button onClick={() => setTitle('Saved')}>{title}</button>
}
it('restores same-tab presentation for its owner only and clears on signout', () => {
  const view = render(<WorkspaceRestoreProvider userId="one" restoring={false}><Page /></WorkspaceRestoreProvider>)
  fireEvent.click(screen.getByRole('button'))
  view.unmount()
  const restored = render(<WorkspaceRestoreProvider userId="one" restoring><Page /></WorkspaceRestoreProvider>)
  expect(screen.getByRole('button')).toHaveTextContent('Saved')
  restored.unmount()
  const other = render(<WorkspaceRestoreProvider userId="two" restoring><Page /></WorkspaceRestoreProvider>)
  expect(screen.getByRole('button')).toHaveTextContent('Default')
  other.unmount()
  clearWorkspaceRestore('one')
  render(<WorkspaceRestoreProvider userId="one" restoring><Page /></WorkspaceRestoreProvider>)
  expect(screen.getByRole('button')).toHaveTextContent('Default')
})
it('ignores unreadable cache entries', () => {
  sessionStorage.setItem('mixtape.workspace.v1:one:test.title', '{')
  render(<WorkspaceRestoreProvider userId="one" restoring={false}><Page /></WorkspaceRestoreProvider>)
  expect(screen.getByRole('button')).toHaveTextContent('Default')
})

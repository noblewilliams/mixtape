import { cleanup, fireEvent, render, screen } from '@testing-library/react'
import { afterEach, expect, it } from 'vitest'
import { clearWorkspaceRestore, openMixOnNextLoad, useRestorableState, useSharedRestorableState, WorkspaceRestoreProvider } from './workspace-restore'

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
it('opens a mix on the next load of the app, for that listener only', () => {
  function Workspace() {
    const [view] = useRestorableState('activeView', 'home')
    const [id] = useRestorableState<string | null>('activeSessionId', null)
    return <p>{view}:{String(id)}</p>
  }
  openMixOnNextLoad('one', 'session-9')
  const own = render(<WorkspaceRestoreProvider userId="one" restoring={false}><Workspace /></WorkspaceRestoreProvider>)
  expect(screen.getByText('session:session-9')).toBeInTheDocument()
  own.unmount()
  render(<WorkspaceRestoreProvider userId="two" restoring={false}><Workspace /></WorkspaceRestoreProvider>)
  expect(screen.getByText('home:null')).toBeInTheDocument()
})

it('keeps one shared value per key, live across every component holding it', () => {
  function Field({ name }: { name: string }) {
    const [text, setText] = useSharedRestorableState('test.shared', '')
    return <button onClick={() => setText((value) => `${value}${name}`)}>{name}:{text}</button>
  }
  const view = render(<WorkspaceRestoreProvider userId="one" restoring={false}><Field name="a" /><Field name="b" /></WorkspaceRestoreProvider>)
  fireEvent.click(screen.getByRole('button', { name: 'a:' }))
  fireEvent.click(screen.getByRole('button', { name: 'b:a' }))
  expect(screen.getByRole('button', { name: 'a:ab' })).toBeInTheDocument()
  view.unmount()
  render(<WorkspaceRestoreProvider userId="one" restoring={false}><Field name="c" /></WorkspaceRestoreProvider>)
  expect(screen.getByRole('button', { name: 'c:ab' })).toBeInTheDocument()
})

it('shares in memory with no listener scope', () => {
  function Field({ name }: { name: string }) {
    const [text, setText] = useSharedRestorableState('test.memory', 0)
    return <button onClick={() => setText((value) => value + 1)}>{name}:{text}</button>
  }
  render(<><Field name="a" /><Field name="b" /></>)
  fireEvent.click(screen.getByRole('button', { name: 'a:0' }))
  expect(screen.getByRole('button', { name: 'b:1' })).toBeInTheDocument()
})

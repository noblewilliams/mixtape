import { act, cleanup, fireEvent, render, screen, waitFor, within } from '@testing-library/react'
import { afterEach, describe, expect, it, vi } from 'vitest'
import { StrictMode } from 'react'
import { AppSettings, DeleteAccountDialog } from './AppSettings'
import type { MixtapeApi, SuggestionsResponse } from '../api/client'
import type { MusicKitClient } from '../musickit/client'
import { PlaybackController } from '../playback/controller'
import { createFakeApi } from '../test/fake-api'

const controllers: PlaybackController[] = []
afterEach(() => { cleanup(); controllers.splice(0).forEach(controller => controller.dispose()) })
const preferences = (enabled: boolean): SuggestionsResponse => ({ enabled, suggestion: null, dismissed: false })
async function setup(api: MixtapeApi, extra: { anonymous?: boolean; onAccountDeleted?: () => void; onSignOut?: () => void; userName?: string; saveName?: (name: string) => Promise<void> } = {}) {
  const playback = new PlaybackController(api, {} as MusicKitClient, 'settings-test')
  controllers.push(playback)
  await playback.initialize()
  return render(<AppSettings api={api} playback={playback} userName={extra.userName ?? 'Test listener'} signInMethod="google" onAccount={vi.fn()} onMemories={vi.fn()} onSignOut={extra.onSignOut ?? vi.fn()} onAccountDeleted={extra.onAccountDeleted ?? vi.fn()} anonymous={extra.anonymous} saveName={extra.saveName ?? vi.fn(async () => undefined)} />)
}
const recommendationToggle = () => screen.getByRole('checkbox', { name: /Recommend mixes/ })

it('reads and saves recommendation preferences from Settings', async () => {
  const save = vi.fn().mockResolvedValue({ enabled: false })
  await setup(createFakeApi({ getSuggestions: async () => preferences(true), saveSuggestionPreference: save }))
  await waitFor(() => expect(recommendationToggle()).toBeChecked())
  fireEvent.click(recommendationToggle())
  await waitFor(() => expect(save).toHaveBeenCalledWith(false))
  await screen.findByText('Listening preferences saved.')
  expect(recommendationToggle()).not.toBeChecked()
})

it('disables changes until the initial preference read resolves', async () => {
  let resolve!: (result: SuggestionsResponse) => void
  const save = vi.fn()
  await setup(createFakeApi({ getSuggestions: () => new Promise(done => { resolve = done }), saveSuggestionPreference: save }))
  expect(recommendationToggle()).toBeDisabled()
  recommendationToggle().click()
  expect(save).not.toHaveBeenCalled()
  await act(async () => resolve(preferences(true)))
  expect(recommendationToggle()).toBeEnabled()
  expect(recommendationToggle()).toBeChecked()
})

it('retries an unavailable preference read before allowing a change', async () => {
  const read = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(preferences(false))
  await setup(createFakeApi({ getSuggestions: read }))
  await screen.findByText('Couldn’t load recommendation preferences.')
  expect(recommendationToggle()).toBeDisabled()
  fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
  await waitFor(() => expect(recommendationToggle()).toBeEnabled())
  expect(recommendationToggle()).not.toBeChecked()
  expect(screen.queryByRole('alert')).not.toBeInTheDocument()
})

it('retains the confirmed preference after a save error and blocks stale changes while retrying', async () => {
  let resolveRetry!: (result: SuggestionsResponse) => void
  const read = vi.fn().mockResolvedValueOnce(preferences(true)).mockImplementationOnce(() => new Promise(done => { resolveRetry = done }))
  const save = vi.fn().mockRejectedValue(new Error('connection lost'))
  await setup(createFakeApi({ getSuggestions: read, saveSuggestionPreference: save }))
  await waitFor(() => expect(recommendationToggle()).toBeChecked())
  fireEvent.click(recommendationToggle())
  await screen.findByText('Couldn’t confirm the change. Retry to check your current preferences.')
  expect(recommendationToggle()).toBeChecked()
  fireEvent.click(screen.getByRole('button', { name: 'Retry' }))
  expect(recommendationToggle()).toBeDisabled()
  recommendationToggle().click()
  expect(save).toHaveBeenCalledTimes(1)
  // The server may have accepted the write even when its response was lost.
  await act(async () => resolveRetry(preferences(false)))
  expect(recommendationToggle()).toBeEnabled()
  expect(recommendationToggle()).not.toBeChecked()
})

it('does not offer a competing retry while listening preferences are saving', async () => {
  let finish!: (result: { enabled: boolean; revision: number }) => void
  await setup(createFakeApi({ savePlaybackPreference: () => new Promise(resolve => { finish = resolve }) }))
  fireEvent.click(screen.getByRole('checkbox', { name: /Learn from my listening/ }))
  expect(screen.queryByText('Listening preferences are unavailable.')).not.toBeInTheDocument()
  expect(screen.queryByRole('button', { name: 'Retry' })).not.toBeInTheDocument()
  await act(async () => finish({ enabled: true, revision: 1 }))
  expect(screen.getByRole('checkbox', { name: /Learn from my listening/ })).toBeChecked()
})

it('restores the last learning preference for display without treating it as live authorization', async () => {
  const { WorkspaceRestoreProvider } = await import('../lib/workspace-restore')
  const api = createFakeApi({ playbackPreferences: async () => ({ enabled: true, revision: 1 }) })
  const live = new PlaybackController(api, {} as MusicKitClient, 'settings-cache-test')
  controllers.push(live)
  await live.initialize()
  const props = { api, userName: 'Listener', signInMethod: 'google', onAccount: vi.fn(), onMemories: vi.fn(), onSignOut: vi.fn(), onAccountDeleted: vi.fn() }
  const view = render(<WorkspaceRestoreProvider userId="settings-cache-test" restoring={false}><AppSettings {...props} playback={live}/></WorkspaceRestoreProvider>)
  expect(screen.getByRole('checkbox', { name: /Learn from my listening/ })).toBeChecked()
  view.unmount()
  const failedApi = createFakeApi({ playbackPreferences: async () => { throw new Error('offline') } })
  const pending = new PlaybackController(failedApi, {} as MusicKitClient, 'settings-cache-test')
  controllers.push(pending)
  const restored = render(<WorkspaceRestoreProvider userId="settings-cache-test" restoring><AppSettings {...props} playback={pending}/></WorkspaceRestoreProvider>)
  expect(screen.getByRole('checkbox', { name: /Learn from my listening/ })).toBeChecked()
  expect(screen.getByRole('checkbox', { name: /Learn from my listening/ })).toBeDisabled()
  expect(screen.queryByText('Listening preferences are unavailable.')).not.toBeInTheDocument()
  await act(async () => pending.initialize())
  restored.rerender(<WorkspaceRestoreProvider userId="settings-cache-test" restoring={false}><AppSettings {...props} playback={pending}/></WorkspaceRestoreProvider>)
  expect(screen.getByRole('checkbox', { name: /Learn from my listening/ })).toBeDisabled()
  expect(screen.getByText('Listening preferences are unavailable.')).toBeInTheDocument()
  sessionStorage.clear()
})

const BODY = 'This permanently deletes your mixes, library, memories and listening history from Mixtape. Your Apple Music and Spotify libraries are not touched.'
const openDelete = () => fireEvent.click(screen.getByRole('button', { name: 'Delete account' }))
const dialog = () => screen.getByRole('alertdialog', { name: 'Delete your account?' })
const confirmButton = () => within(dialog()).getByRole('button', { name: /Delete account|Deleting/ })

it('offers Delete account to accounts only', async () => {
  await setup(createFakeApi())
  expect(screen.getByRole('button', { name: 'Delete account' })).toHaveClass('wc-danger')
  expect(screen.queryByText('Delete your Mixtape account')).not.toBeInTheDocument()
  cleanup()
  await setup(createFakeApi(), { anonymous: true })
  expect(screen.queryByRole('button', { name: 'Delete account' })).not.toBeInTheDocument()
})

it('confirms before deleting and Cancel leaves the account alone', async () => {
  const deleteAccount = vi.fn()
  await setup(createFakeApi({ deleteAccount }))
  openDelete()
  expect(within(dialog()).getByText(BODY)).toBeInTheDocument()
  fireEvent.click(within(dialog()).getByRole('button', { name: 'Cancel' }))
  expect(screen.queryByRole('alertdialog')).not.toBeInTheDocument()
  expect(deleteAccount).not.toHaveBeenCalled()
})

it('deletes once while in flight and then signs out locally', async () => {
  let finish!: (value: { deleted: true; apple: 'not_linked' }) => void
  const deleteAccount = vi.fn(() => new Promise<{ deleted: true; apple: 'not_linked' }>(done => { finish = done }))
  const onAccountDeleted = vi.fn()
  const onSignOut = vi.fn()
  await setup(createFakeApi({ deleteAccount }), { onAccountDeleted, onSignOut })
  openDelete()
  fireEvent.click(confirmButton())
  expect(confirmButton()).toBeDisabled()
  expect(within(dialog()).getByRole('button', { name: 'Cancel' })).toBeDisabled()
  fireEvent.click(confirmButton())
  expect(deleteAccount).toHaveBeenCalledOnce()
  expect(onAccountDeleted).not.toHaveBeenCalled()
  await act(async () => finish({ deleted: true, apple: 'not_linked' }))
  expect(onAccountDeleted).toHaveBeenCalledOnce()
  expect(onSignOut).not.toHaveBeenCalled()
})

it('shows the failure inline and lets the listener try again', async () => {
  const deleteAccount = vi.fn()
    .mockRejectedValueOnce(new Error('offline'))
    .mockResolvedValueOnce({ deleted: true, apple: 'revoked' })
  const onAccountDeleted = vi.fn()
  await setup(createFakeApi({ deleteAccount }), { onAccountDeleted })
  openDelete()
  fireEvent.click(confirmButton())
  expect(await within(dialog()).findByText('Couldn’t delete your account. Try again.')).toBeInTheDocument()
  expect(onAccountDeleted).not.toHaveBeenCalled()
  expect(confirmButton()).toBeEnabled()
  fireEvent.click(confirmButton())
  await waitFor(() => expect(onAccountDeleted).toHaveBeenCalledOnce())
  expect(deleteAccount).toHaveBeenCalledTimes(2)
})

it('shows the failure under StrictMode, where effects mount twice', async () => {
  render(<StrictMode><DeleteAccountDialog deleteAccount={() => Promise.reject(new Error('offline'))} onDeleted={vi.fn()} onClose={vi.fn()} /></StrictMode>)
  fireEvent.click(confirmButton())
  expect(await within(dialog()).findByText('Couldn’t delete your account. Try again.')).toBeInTheDocument()
  expect(confirmButton()).toBeEnabled()
})

/** Sets the value the way a browser does (caret after the inserted text), so the change handler sees the selection. */
function typeInto(input: HTMLElement, value: string, caret?: number, composing = false) {
  const element = input as HTMLInputElement
  Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value')!.set!.call(element, value)
  element.setSelectionRange(caret ?? value.length, caret ?? value.length)
  fireEvent.input(element, { isComposing: composing })
}

describe('the name in Settings › Account', () => {
  const field = () => screen.getByRole('textbox', { name: 'Your name' })
  const editName = () => screen.getByRole('button', { name: 'Edit name' })
  const HINT = 'Up to 40 characters. Leave it blank to remove your name.'

  it('reads "Your account" with Add name when the name is blank', async () => {
    await setup(createFakeApi(), { userName: '  ' })
    expect(screen.getByText('Your account')).toBeInTheDocument()
    // WCAG 2.5.3: the accessible name is the visible text.
    expect(screen.getByRole('button', { name: 'Add name' })).toHaveTextContent('Add name')
    expect(screen.queryByRole('button', { name: 'Edit name' })).not.toBeInTheDocument()
  })

  it('offers Edit name before Manage account for a named account', async () => {
    await setup(createFakeApi(), { userName: 'Ada Okafor' })
    expect(screen.getByText('Ada Okafor')).toBeInTheDocument()
    const buttons = screen.getAllByRole('button').map(button => button.textContent)
    expect(buttons.indexOf('Edit name')).toBeGreaterThan(-1)
    expect(buttons.indexOf('Edit name')).toBe(buttons.indexOf('Manage account') - 1)
  })

  it('is hidden for anonymous listeners', async () => {
    await setup(createFakeApi(), { anonymous: true, userName: 'Listener' })
    expect(screen.queryByRole('button', { name: /Edit name|Add name/ })).not.toBeInTheDocument()
    expect(screen.queryByText('Your account')).not.toBeInTheDocument()
  })

  it('edits inline: the name becomes a focused field described by the hint', async () => {
    await setup(createFakeApi(), { userName: 'Ada Okafor' })
    fireEvent.click(editName())
    expect(field()).toHaveValue('Ada Okafor')
    expect(field()).toHaveFocus()
    expect(field()).toHaveAccessibleDescription(HINT)
    expect(screen.getByRole('button', { name: 'Save' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: 'Manage account' })).not.toBeInTheDocument()
  })

  it('Escape and Cancel leave the name alone and return focus to Edit name', async () => {
    const saveName = vi.fn(async () => undefined)
    await setup(createFakeApi(), { userName: 'Ada Okafor', saveName })
    fireEvent.click(editName())
    fireEvent.change(field(), { target: { value: 'Grace' } })
    fireEvent.keyDown(field(), { key: 'Escape' })
    expect(screen.queryByRole('textbox', { name: 'Your name' })).not.toBeInTheDocument()
    expect(editName()).toHaveFocus()
    fireEvent.click(editName())
    expect(field()).toHaveValue('Ada Okafor')
    fireEvent.click(screen.getByRole('button', { name: 'Cancel' }))
    expect(editName()).toHaveFocus()
    expect(saveName).not.toHaveBeenCalled()
  })

  it('Enter saves, announces "Name saved" and returns focus to Edit name', async () => {
    const saveName = vi.fn(async () => undefined)
    await setup(createFakeApi(), { userName: 'Ada Okafor', saveName })
    fireEvent.click(editName())
    fireEvent.change(field(), { target: { value: 'Grace Hopper' } })
    fireEvent.keyDown(field(), { key: 'Enter' })
    await waitFor(() => expect(screen.queryByRole('textbox', { name: 'Your name' })).not.toBeInTheDocument())
    expect(saveName).toHaveBeenCalledWith('Grace Hopper')
    expect(editName()).toHaveFocus()
    // Announced a beat after focus lands, so a screen reader reads both.
    await waitFor(() => expect(screen.getByRole('status')).toHaveTextContent('Name saved'))
  })

  it('shows Saving… with the field read-only and the actions disabled', async () => {
    let finish!: () => void
    await setup(createFakeApi(), { userName: 'Ada Okafor', saveName: () => new Promise<void>(done => { finish = done }) })
    fireEvent.click(editName())
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    expect(screen.getByRole('status')).toHaveTextContent('Saving…')
    expect(field()).toHaveAttribute('readonly')
    expect(screen.getByRole('button', { name: 'Save' })).toBeDisabled()
    expect(screen.getByRole('button', { name: 'Cancel' })).toBeDisabled()
    fireEvent.keyDown(field(), { key: 'Escape' })
    expect(field()).toBeInTheDocument()
    await act(async () => finish())
  })

  it('saves a blank field as a removal and announces "Name removed"', async () => {
    const saveName = vi.fn(async () => undefined)
    await setup(createFakeApi(), { userName: 'Ada Okafor', saveName })
    fireEvent.click(editName())
    fireEvent.change(field(), { target: { value: '   ' } })
    expect(field()).toHaveAccessibleDescription('Saving a blank name removes it.')
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(saveName).toHaveBeenCalledWith(''))
    expect(await screen.findByText('Name removed')).toBeInTheDocument()
  })

  it('stops at 40 characters, counts from 30 and says why a paste was cut', async () => {
    await setup(createFakeApi(), { userName: '' })
    fireEvent.click(screen.getByRole('button', { name: 'Add name' }))
    fireEvent.change(field(), { target: { value: 'a'.repeat(29) } })
    expect(screen.queryByText(/of 40/)).not.toBeInTheDocument()
    fireEvent.change(field(), { target: { value: 'a'.repeat(30) } })
    expect(screen.getByText('30 of 40')).toBeInTheDocument()
    fireEvent.change(field(), { target: { value: 'Oluwaseun Adaeze Okafor-Whitfield Balogun' } })
    expect(field()).toHaveValue('Oluwaseun Adaeze Okafor-Whitfield Balogu')
    expect(screen.getByText('40 of 40')).toBeInTheDocument()
    expect(field()).toHaveAccessibleDescription(/Names stop at 40 characters\./)
  })

  it('keeps joined emoji and ZWNJ spellings and never splits a flag at the cap', async () => {
    await setup(createFakeApi(), { userName: '' })
    fireEvent.click(screen.getByRole('button', { name: 'Add name' }))
    typeInto(field(), 'Ada 👩‍👩‍👧 می\u200cخواهم')
    expect(field()).toHaveValue('Ada 👩‍👩‍👧 می\u200cخواهم')
    typeInto(field(), 'a'.repeat(39))
    typeInto(field(), `${'a'.repeat(39)}🇳🇬`)
    expect(field()).toHaveValue('a'.repeat(39))
    expect(field()).toHaveAccessibleDescription(/Names stop at 40 characters\./)
  })

  it('refuses a mid-text insert at the cap and keeps the text after the caret', async () => {
    await setup(createFakeApi(), { userName: '' })
    fireEvent.click(screen.getByRole('button', { name: 'Add name' }))
    const full = 'b'.repeat(20) + 'c'.repeat(20)
    typeInto(field(), full)
    typeInto(field(), 'b'.repeat(20) + 'X' + 'c'.repeat(20), 21)
    expect(field()).toHaveValue(full)
    expect((field() as HTMLInputElement).selectionStart).toBe(20)
  })

  it('ignores Enter and Escape while an IME is composing and limits on compositionend', async () => {
    const saveName = vi.fn(async () => undefined)
    await setup(createFakeApi(), { userName: '', saveName })
    fireEvent.click(screen.getByRole('button', { name: 'Add name' }))
    fireEvent.compositionStart(field())
    typeInto(field(), 'a'.repeat(45), undefined, true)
    expect(field()).toHaveValue('a'.repeat(45))
    fireEvent.keyDown(field(), { key: 'Enter', isComposing: true })
    fireEvent.keyDown(field(), { key: 'Escape', keyCode: 229 })
    expect(saveName).not.toHaveBeenCalled()
    expect(field()).toBeInTheDocument()
    fireEvent.compositionEnd(field())
    expect(field()).toHaveValue('a'.repeat(40))
  })

  it('saves the name in the server shape', async () => {
    const saveName = vi.fn(async () => undefined)
    await setup(createFakeApi(), { userName: 'Ada', saveName })
    fireEvent.click(editName())
    typeInto(field(), '  Grace   Hopper ')
    fireEvent.keyDown(field(), { key: 'Enter' })
    await waitFor(() => expect(saveName).toHaveBeenCalledWith('Grace Hopper'))
  })

  it('shows the saved name until the session catches up', async () => {
    await setup(createFakeApi(), { userName: 'Ada Okafor', saveName: vi.fn(async () => undefined) })
    fireEvent.click(editName())
    typeInto(field(), 'Grace  Hopper')
    fireEvent.keyDown(field(), { key: 'Enter' })
    expect(await screen.findByText('Grace Hopper')).toBeInTheDocument()
    expect(screen.queryByText('Ada Okafor')).not.toBeInTheDocument()
  })

  it('editing after a failure brings back the hint, the count and Save', async () => {
    await setup(createFakeApi(), { userName: 'Ada Okafor', saveName: vi.fn().mockRejectedValue(new Error('offline')) })
    fireEvent.click(editName())
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    await screen.findByRole('alert')
    typeInto(field(), 'a'.repeat(31))
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
    expect(field()).not.toHaveAttribute('aria-invalid')
    expect(screen.getByText('31 of 40')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Save' })).toBeInTheDocument()
  })

  it('keeps the text after a failure and offers Retry', async () => {
    const saveName = vi.fn().mockRejectedValueOnce(new Error('offline')).mockResolvedValueOnce(undefined)
    await setup(createFakeApi(), { userName: 'Ada Okafor', saveName })
    fireEvent.click(editName())
    fireEvent.change(field(), { target: { value: 'Grace Hopper' } })
    fireEvent.click(screen.getByRole('button', { name: 'Save' }))
    expect(await screen.findByRole('alert')).toHaveTextContent('Couldn’t save your name.')
    expect(field()).toHaveValue('Grace Hopper')
    expect(field()).toHaveAttribute('aria-invalid', 'true')
    const retry = screen.getByRole('button', { name: 'Retry' })
    expect(retry).toHaveFocus()
    fireEvent.click(retry)
    await waitFor(() => expect(saveName).toHaveBeenCalledTimes(2))
    expect(saveName).toHaveBeenLastCalledWith('Grace Hopper')
    expect(await screen.findByText('Name saved')).toBeInTheDocument()
  })
})

it('links the privacy policy in a new tab, for accounts and anonymous listeners alike', async () => {
  for (const anonymous of [false, true]) {
    await setup(createFakeApi(), { anonymous })
    const link = screen.getByRole('link', { name: 'Privacy policy' })
    expect(link).toHaveAttribute('href', 'https://miixtape.netlify.app/privacy/')
    expect(link).toHaveAttribute('target', '_blank')
    expect(link).toHaveAttribute('rel', expect.stringContaining('noopener'))
    cleanup()
  }
})

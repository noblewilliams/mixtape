import type { ReactNode } from 'react'
import type { CollectionView } from '../domain'
import './tabs.css'

const views: { id: CollectionView; label: string; icon: ReactNode }[] = [
  { id: 'list', label: 'List view', icon: <><circle cx="4.5" cy="6" r="1" /><circle cx="4.5" cy="12" r="1" /><circle cx="4.5" cy="18" r="1" /><path d="M9 6h11M9 12h11M9 18h11" /></> },
  { id: 'grid', label: 'Grid view', icon: <><rect x="4" y="4" width="6.5" height="6.5" rx="1.5" /><rect x="13.5" y="4" width="6.5" height="6.5" rx="1.5" /><rect x="4" y="13.5" width="6.5" height="6.5" rx="1.5" /><rect x="13.5" y="13.5" width="6.5" height="6.5" rx="1.5" /></> },
  { id: 'closet', label: 'Closet view', icon: <><rect x="4.5" y="4.5" width="3.6" height="12" rx="1" /><rect x="10" y="4.5" width="3.6" height="12" rx="1" /><rect x="15.4" y="5.6" width="3.6" height="11" rx="1" transform="rotate(14 17.2 16.6)" /><path d="M3 19.5h18" /></> },
]

export function ViewSwitch({ value, onChange }: { value: CollectionView; onChange: (view: CollectionView) => void }) {
  return <div className="view-toggle" role="group" aria-label="Collection view">
    {views.map(view => <button key={view.id} type="button" aria-pressed={value === view.id} aria-label={view.label} title={view.label} onClick={() => onChange(view.id)}>
      <svg viewBox="0 0 24 24" aria-hidden="true" focusable="false">{view.icon}</svg>
    </button>)}
  </div>
}

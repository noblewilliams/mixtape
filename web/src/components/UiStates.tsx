import { TapeRackSkeleton } from './TapeRack'
import type { CollectionView } from '../domain'
export function EmptyState({ kind = 'tape', title, description, action }: { kind?: 'tape' | 'memory' | 'error'; title: string; description: string; action?: { label: string; onClick: () => void } }) {
  const art = kind === 'memory' ? 'memory-object' : kind === 'error' ? 'connection-object' : 'cassette'
  return <section className="polish-empty" role={kind === 'error' ? 'alert' : undefined}>
    <img src={kind === 'tape' ? '/tape.svg' : `/ui/${art}.svg`} alt="" />
    <h2>{title}</h2><p>{description}</p>
    {action && <button className={kind === 'error' ? 'minimal-retry' : 'dialog-confirm'} onClick={action.onClick}>{action.label}</button>}
  </section>
}
export function MixSkeletons({ count = 3, view = 'list' }: { count?: number; view?: CollectionView }) {
  if (view === 'closet') return <TapeRackSkeleton />
  if (view === 'grid') return <div className="mix-skeletons mix-skeletons-grid" role="status" aria-label="Loading mixes">
    {Array.from({ length: 6 }, (_, i) => <div className="mix-skeleton-tile" key={i} aria-hidden="true"><div className="skeleton-tape" /><div className="skeleton-copy"><span /><small /></div></div>)}
  </div>
  return <div className="mix-skeletons" role="status" aria-label="Loading mixes">
    {Array.from({ length: count }, (_, i) => <div className="mix-skeleton" key={i} aria-hidden="true"><div className="skeleton-cassette"><i /><i /></div><div className="skeleton-copy"><span /><small /></div></div>)}
  </div>
}

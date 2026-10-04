import './tabs.css'

export type TabItem<T extends string> = { id: T; label: string }

export function Tabs<T extends string>({ label, items, current, onSelect }: { label: string; items: TabItem<T>[]; current: T; onSelect: (id: T) => void }) {
  return <nav className="tabs" aria-label={label}>
    {items.map(item => <button key={item.id} type="button" aria-current={item.id === current ? 'page' : undefined} onClick={() => onSelect(item.id)}>{item.label}</button>)}
  </nav>
}

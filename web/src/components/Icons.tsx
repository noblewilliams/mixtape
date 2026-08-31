import type { SVGProps } from 'react'

type IconProps = SVGProps<SVGSVGElement>

const iconDefaults = {
  width: 20,
  height: 20,
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.8,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  'aria-hidden': true,
}

export function HomeIcon(props: IconProps) {
  return (
    <svg {...iconDefaults} {...props}>
      <path d="m3.5 10 8.5-7 8.5 7v10.5h-6v-6h-5v6h-6z" />
    </svg>
  )
}

export function PlusIcon(props: IconProps) {
  return (
    <svg {...iconDefaults} {...props}>
      <path d="M12 5v14M5 12h14" />
    </svg>
  )
}

export function SendIcon(props: IconProps) {
  return (
    <svg {...iconDefaults} {...props}>
      <path d="M12 19V5M8 9l4-4 4 4" />
    </svg>
  )
}

export function QueueIcon(props: IconProps) {
  return (
    <svg {...iconDefaults} {...props}>
      <path d="M8 7h12M8 12h12M8 17h12" />
      <circle cx="4" cy="7" r=".8" fill="currentColor" stroke="none" />
      <circle cx="4" cy="12" r=".8" fill="currentColor" stroke="none" />
      <circle cx="4" cy="17" r=".8" fill="currentColor" stroke="none" />
    </svg>
  )
}

export function SyncIcon(props: IconProps) {
  return (
    <svg {...iconDefaults} {...props}>
      <path d="M20 7v5h-5M4 17v-5h5" />
      <path d="M6.1 8.2A7 7 0 0 1 18.4 6L20 8M4 16l1.6 2A7 7 0 0 0 18 15.8" />
    </svg>
  )
}

export function SignOutIcon(props: IconProps) {
  return (
    <svg {...iconDefaults} {...props}>
      <path d="M10 5H5.5A1.5 1.5 0 0 0 4 6.5v11A1.5 1.5 0 0 0 5.5 19H10" />
      <path d="m14 8 4 4-4 4M18 12H9" />
    </svg>
  )
}

export function CloseIcon(props: IconProps) {
  return (
    <svg {...iconDefaults} {...props}>
      <path d="m6 6 12 12M18 6 6 18" />
    </svg>
  )
}

export function MoreIcon(props: IconProps) {
  return (
    <svg {...iconDefaults} {...props}>
      <circle cx="5" cy="12" r="1" fill="currentColor" stroke="none" />
      <circle cx="12" cy="12" r="1" fill="currentColor" stroke="none" />
      <circle cx="19" cy="12" r="1" fill="currentColor" stroke="none" />
    </svg>
  )
}

export function SuccessCircleIcon(props: IconProps) {
  return (
    <svg {...iconDefaults} {...props}>
      <circle cx="12" cy="12" r="9" />
      <path d="m7.8 12.2 2.8 2.8 5.8-6.1" />
    </svg>
  )
}

export function ErrorCircleIcon(props: IconProps) {
  return (
    <svg {...iconDefaults} {...props}>
      <circle cx="12" cy="12" r="9" />
      <path d="M12 7.5v6M12 17h.01" />
    </svg>
  )
}

export function PlayIcon({ paused = false, ...props }: IconProps & { paused?: boolean }) {
  return (
    <svg {...iconDefaults} {...props}>
      {paused ? (
        <>
          <path d="M9 7v10M15 7v10" strokeWidth="2.5" />
        </>
      ) : (
        <path d="m9 7 8 5-8 5z" fill="currentColor" stroke="none" />
      )}
    </svg>
  )
}

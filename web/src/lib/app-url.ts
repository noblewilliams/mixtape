/** Keep browser authentication returns inside the app's Vite base path. */
export function appReturnUrl(origin: string, base: string, query?: Record<string, string>): string {
  const url = new URL(base, origin)
  if (query) url.search = new URLSearchParams(query).toString()
  return url.href
}

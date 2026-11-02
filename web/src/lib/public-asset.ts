// Files in web/public are served under the app's base (/app/ in production,
// / in dev). A root-relative path resolves to the landing page's root
// on the shared domain and 404s, so every public asset goes through here.
export function publicAsset(path: string, base: string = import.meta.env.BASE_URL): string {
  return `${base.replace(/\/$/, '')}/${path.replace(/^\//, '')}`
}

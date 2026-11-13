const configuredApiUrl = import.meta.env.VITE_API_URL?.trim()

type ServiceUrlInput = {
  configuredApiUrl?: string
  isProduction: boolean
  pageOrigin: string
}

type ServiceUrls = {
  apiUrl: string
  authUrl: string
}

const withoutTrailingSlash = (value: string) => value.replace(/\/+$/, '')

export function resolveServiceUrls({ configuredApiUrl, isProduction, pageOrigin }: ServiceUrlInput): ServiceUrls {
  const directApiUrl = withoutTrailingSlash(configuredApiUrl || 'http://localhost:8787')

  if (isProduction) {
    const origin = withoutTrailingSlash(pageOrigin)
    return {
      apiUrl: directApiUrl,
      authUrl: origin,
    }
  }

  return {
    apiUrl: directApiUrl,
    authUrl: directApiUrl,
  }
}

const serviceUrls = resolveServiceUrls({
  configuredApiUrl,
  isProduction: import.meta.env.PROD,
  pageOrigin: window.location.origin,
})

export const API_URL = serviceUrls.apiUrl
export const AUTH_URL = serviceUrls.authUrl

/**
 * Where "Get the app" goes: the landing page's download link when the build
 * has one (VITE_DOWNLOAD_URL, shared with the landing build), else the landing
 * page itself, which explains when the download is not available yet.
 */
export const DOWNLOAD_URL = import.meta.env.VITE_DOWNLOAD_URL?.trim() || '/'

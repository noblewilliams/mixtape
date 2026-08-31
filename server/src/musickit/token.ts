import { importPKCS8, SignJWT } from 'jose'

const APPLE_MAX_TOKEN_TTL_SECONDS = 15_777_000

export async function generateMusicKitDeveloperToken({
  teamId,
  keyId,
  privateKey,
  origin,
  nowSeconds = Math.floor(Date.now() / 1000),
  ttlSeconds = 60 * 60,
}: {
  teamId: string
  keyId: string
  privateKey: string
  origin: string
  nowSeconds?: number
  ttlSeconds?: number
}): Promise<{ developerToken: string; expiresAt: number }> {
  if (!teamId) throw new Error('MusicKit team ID is required')
  if (!keyId) throw new Error('MusicKit key ID is required')
  if (!privateKey) throw new Error('MusicKit private key is required')
  if (!origin) throw new Error('MusicKit web origin is required')
  if (!Number.isInteger(ttlSeconds) || ttlSeconds < 1 || ttlSeconds > APPLE_MAX_TOKEN_TTL_SECONDS) {
    throw new Error('MusicKit token TTL is outside Apple limits')
  }

  const signingKey = await importPKCS8(privateKey.replace(/\\n/g, '\n'), 'ES256')
  const expiresAt = nowSeconds + ttlSeconds
  const developerToken = await new SignJWT({ origin: [origin] })
    .setProtectedHeader({ alg: 'ES256', kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt(nowSeconds)
    .setExpirationTime(expiresAt)
    .sign(signingKey)

  return { developerToken, expiresAt }
}

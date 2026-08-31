import { exportPKCS8, generateKeyPair } from 'jose'
import type { AuthEnv } from '../../src/auth/create-auth'

const { privateKey } = await generateKeyPair('ES256', { extractable: true })

export const testApplePrivateKey = await exportPKCS8(privateKey)

export const testAuthEnv: AuthEnv = {
  BETTER_AUTH_SECRET: 'test-secret-test-secret-test-secret',
  BETTER_AUTH_URL: 'http://localhost:8787',
  APPLE_BUNDLE_ID: 'com.noble.mixtape',
  APPLE_WEB_CLIENT_ID: 'com.noble.mixtape.web',
  APPLE_TEAM_ID: 'TEAM123456',
  APPLE_KEY_ID: 'KEY1234567',
  APPLE_PRIVATE_KEY: testApplePrivateKey,
  GOOGLE_CLIENT_ID: 'google-client-id.apps.googleusercontent.com',
  GOOGLE_CLIENT_SECRET: 'google-client-secret',
  WEB_ORIGINS: 'http://localhost:4176, https://mixtape.example.com',
}

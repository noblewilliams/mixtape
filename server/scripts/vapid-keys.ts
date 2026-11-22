// Prints a fresh VAPID key pair for web push (spec "Web push" → Keys).
//
//   npx tsx scripts/vapid-keys.ts
//
// VAPID_PUBLIC_KEY: base64url (no padding) uncompressed P-256 point, 65
//   bytes starting 0x04. A wrangler var; /health serves it to the web app as
//   the pushManager.subscribe applicationServerKey.
// VAPID_PRIVATE_KEY: base64url raw private scalar d, 32 bytes. A secret:
//   `wrangler secret put VAPID_PRIVATE_KEY`, never committed.
//
// The same formats as `npx web-push generate-vapid-keys`, and the formats
// src/push/webpush.ts reads. Rotating the pair invalidates every existing
// web subscription (they were made against the old public key).
import { base64UrlEncode } from '../src/push/webpush'

const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
const publicKey = base64UrlEncode(new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey)))
// A JWK's d is already the base64url raw scalar.
const privateKey = (await crypto.subtle.exportKey('jwk', pair.privateKey)).d!

console.log(`VAPID_PUBLIC_KEY=${publicKey}`)
console.log(`VAPID_PRIVATE_KEY=${privateKey}`)

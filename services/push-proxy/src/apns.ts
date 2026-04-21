import { base64UrlEncode, pemToArrayBuffer } from "./crypto"
import { Env } from "./types"

let cachedJWT: { token: string; expires: number } | null = null

async function generateAPNsJWT(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000)
  if (cachedJWT && now < cachedJWT.expires) return cachedJWT.token

  const header = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }))
  )
  const claims = base64UrlEncode(
    new TextEncoder().encode(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }))
  )
  const signingInput = `${header}.${claims}`

  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(env.APNS_PRIVATE_KEY),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"]
  )
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(signingInput)
  )

  const token = `${signingInput}.${base64UrlEncode(signature)}`
  cachedJWT = { token, expires: now + 50 * 60 }
  return token
}

function apnsHost(environment: "production" | "sandbox"): string {
  return environment === "production"
    ? "https://api.push.apple.com"
    : "https://api.sandbox.push.apple.com"
}

export async function sendSilentPush(
  env: Env,
  pushToken: string,
  apnsEnvironment: "production" | "sandbox" = "production"
): Promise<{ ok: boolean; gone: boolean }> {
  const jwt = await generateAPNsJWT(env)

  const resp = await fetch(`${apnsHost(apnsEnvironment)}/3/device/${pushToken}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-push-type": "background",
      "apns-topic": "com.sigkitten.litter",
      "apns-priority": "5",
    },
    body: JSON.stringify({ aps: { "content-available": 1 } }),
  })

  if (resp.status !== 200) {
    const body = await resp.text()
    console.log(`APNs ${apnsEnvironment} → ${resp.status}: ${body} (token=${pushToken.slice(0, 8)}...)`)
  } else {
    console.log(`APNs ${apnsEnvironment} → 200 OK`)
  }

  return { ok: resp.status === 200, gone: resp.status === 410 }
}

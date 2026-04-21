import { Env, RegisterRequest } from "./types"

export { PushRegistration } from "./durable-object"
export { RateLimiter } from "./rate-limiter"

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { "content-type": "application/json" },
  })
}

function decodeJWSPayload(jws: string): any {
  const parts = jws.split(".")
  if (parts.length !== 3) return null
  const padded = parts[1].replace(/-/g, "+").replace(/_/g, "/")
  return JSON.parse(atob(padded))
}

async function handleAppleWebhook(request: Request, env: Env): Promise<Response> {
  const body = await request.json() as { signedPayload?: string }
  if (!body.signedPayload) return json({ error: "missing signedPayload" }, 400)

  const payload = decodeJWSPayload(body.signedPayload)
  if (!payload) return json({ error: "invalid JWS" }, 400)

  const notificationType = payload.notificationType
  const subtype = payload.subtype || ""

  let transaction: any = null
  const signedTx = payload.data?.signedTransactionInfo
  if (signedTx) transaction = decodeJWSPayload(signedTx)

  const productId = transaction?.productId || "unknown"
  const price = transaction?.price != null ? (transaction.price / 1000).toFixed(2) : "?"
  const currency = transaction?.currency || ""
  const storefront = transaction?.storefront || ""
  const environment = payload.data?.environment || "unknown"
  const transactionId = transaction?.transactionId || "unknown"
  const purchaseDate = transaction?.purchaseDate
    ? new Date(transaction.purchaseDate).toISOString()
    : new Date().toISOString()

  // Only log purchase events
  const purchaseTypes = ["ONE_TIME_CHARGE", "SUBSCRIBED", "DID_RENEW"]
  if (!purchaseTypes.includes(notificationType)) {
    return json({ ok: true })
  }

  const key = `purchase:${Date.now()}`
  await env.PUSH_KV.put(key, JSON.stringify({
    type: notificationType,
    subtype,
    productId,
    price,
    currency,
    storefront,
    environment,
    transactionId,
    purchaseDate,
    receivedAt: new Date().toISOString(),
  }), { expirationTtl: 60 * 60 * 24 * 365 }) // keep for 1 year

  return json({ ok: true })
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url)
    const parts = url.pathname.split("/").filter(Boolean)

    // Apple App Store Server Notifications webhook
    if (request.method === "POST" && parts.length === 1 && parts[0] === "apple-webhook") {
      return handleAppleWebhook(request, env)
    }

    if (request.method === "POST" && parts.length === 1 && parts[0] === "register") {
      const ip = request.headers.get("cf-connecting-ip") ?? "unknown"
      const limitId = env.RATE_LIMITER.idFromName(ip)
      const limiter = env.RATE_LIMITER.get(limitId)
      const limitResp = await limiter.fetch(new Request("https://rl/check"))
      if (limitResp.status === 429) {
        return json({ error: "rate limited" }, 429)
      }

      const body = (await request.json()) as RegisterRequest
      const id = env.PUSH_REGISTRATION.newUniqueId()
      const stub = env.PUSH_REGISTRATION.get(id)
      await stub.fetch(new Request("https://do/", { method: "PUT", body: JSON.stringify(body) }))

      return json({ id: id.toString() })
    }

    if (parts.length === 2 && request.method === "POST") {
      const [doId, action] = parts
      if (!["deregister"].includes(action)) return json({ error: "not found" }, 404)
      const id = env.PUSH_REGISTRATION.idFromString(doId)
      const stub = env.PUSH_REGISTRATION.get(id)
      const doReq = new Request(`https://do/${action}`, {
        method: "POST",
        body: request.body,
        headers: request.headers,
      })
      const resp = await stub.fetch(doReq)
      return new Response(resp.body, { status: resp.status })
    }

    return json({ error: "not found" }, 404)
  },
}

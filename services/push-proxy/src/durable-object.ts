import { sendSilentPush } from "./apns"
import { Env, RegisterRequest } from "./types"

interface StoredRegistration {
  platform: "ios" | "android"
  pushToken: string
  apnsEnvironment: "production" | "sandbox"
  intervalSeconds: number
  ttlSeconds: number
  pushCount: number
  createdAt: number // ms
}

export class PushRegistration implements DurableObject {
  private state: DurableObjectState
  private env: Env

  constructor(state: DurableObjectState, env: Env) {
    this.state = state
    this.env = env
  }

  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url)

    if (request.method === "PUT" && url.pathname === "/") {
      const body = (await request.json()) as RegisterRequest
      const reg: StoredRegistration = {
        platform: body.platform,
        pushToken: body.pushToken,
        apnsEnvironment: body.apnsEnvironment ?? "production",
        intervalSeconds: body.intervalSeconds ?? 30,
        ttlSeconds: body.ttlSeconds ?? 7200,
        pushCount: 0,
        createdAt: Date.now(),
      }
      await this.state.storage.put("reg", reg)
      await this.state.storage.setAlarm(Date.now() + reg.intervalSeconds * 1000)
      return new Response("ok")
    }

    if (request.method === "POST" && url.pathname === "/deregister") {
      await this.state.storage.deleteAll()
      return new Response("ok")
    }

    return new Response("not found", { status: 404 })
  }

  async alarm(): Promise<void> {
    const reg = await this.state.storage.get<StoredRegistration>("reg")
    if (!reg) return

    const now = Date.now()
    if (reg.createdAt + reg.ttlSeconds * 1000 < now) {
      console.log(`TTL expired after ${reg.pushCount} pushes`)
      await this.state.storage.deleteAll()
      return
    }

    reg.pushCount++

    if (reg.platform === "ios") {
      const result = await sendSilentPush(this.env, reg.pushToken, reg.apnsEnvironment)
      if (result.gone) {
        await this.state.storage.deleteAll()
        return
      }
    }

    await this.state.storage.put("reg", reg)
    await this.state.storage.setAlarm(now + reg.intervalSeconds * 1000)
  }
}

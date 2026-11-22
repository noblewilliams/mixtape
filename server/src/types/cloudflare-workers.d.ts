// Minimal structural stand-in for the runtime's 'cloudflare:workers' module.
// This project's tsconfig doesn't pull in @cloudflare/workers-types (see
// ScheduledController in src/index.ts), so only what TurnRunner uses is
// declared. Wrangler's bundler leaves the import to the runtime; in Node
// tests vitest.config.ts aliases it to test/helpers/cloudflare-workers.ts.
declare module 'cloudflare:workers' {
  export interface DurableObjectStorage {
    get<T = unknown>(key: string): Promise<T | undefined>
    put<T>(key: string, value: T): Promise<void>
    delete(key: string): Promise<boolean>
    setAlarm(scheduledTime: number | Date): Promise<void>
  }

  export interface DurableObjectState {
    readonly storage: DurableObjectStorage
  }

  export abstract class DurableObject<Env = unknown> {
    protected ctx: DurableObjectState
    protected env: Env
    constructor(ctx: DurableObjectState, env: Env)
  }
}

// What 'cloudflare:workers' gives src/index.ts in Node tests (aliased in
// vitest.config.ts): a base class that keeps ctx and env, as the runtime's
// does. TurnRunner's behaviour is tested through TurnRunnerCore
// (src/dj/turn-runner.ts), so nothing here pretends to be the platform.
export class DurableObject<Env = unknown> {
  constructor(
    protected ctx: unknown,
    protected env: Env,
  ) {}
}

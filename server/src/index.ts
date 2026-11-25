// Cloudflare Worker entry point. One Durable Object per session holds that
// session's contacts and timers; it deletes everything when the session ends.

import { DurableObject } from 'cloudflare:workers';
import { handle } from './router.ts';
import { SessionRunner, type CallResult, type Operation, type Storage } from './runner.ts';
import type { CreateInput, SessionState } from './session.ts';
import { sendText, type TwilioConfig } from './twilio.ts';

export interface Env extends TwilioConfig {
  SESSIONS: DurableObjectNamespace<SessionObject>;
  APP_KEY?: string;
  TEXT_LIMITER?: { limit(options: { key: string }): Promise<{ success: boolean }> };
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, {
      appKey: env.APP_KEY,
      sessions: {
        create: (id, input, token) => env.SESSIONS.get(env.SESSIONS.idFromName(id)).create(input, token),
        call: (id, token, operation) => env.SESSIONS.get(env.SESSIONS.idFromName(id)).call(token, operation),
      },
      send: (to, body) => sendText(env, to, body),
      limit: async (key) => (env.TEXT_LIMITER ? (await env.TEXT_LIMITER.limit({ key })).success : true),
      now: () => Date.now(),
      randomId: () => crypto.randomUUID(),
      randomToken: () => {
        const bytes = crypto.getRandomValues(new Uint8Array(32));
        return Array.from(bytes, (b) => b.toString(16).padStart(2, '0')).join('');
      },
    });
  },
} satisfies ExportedHandler<Env>;

export class SessionObject extends DurableObject<Env> {
  private runner: SessionRunner;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    const storage: Storage = {
      get: () => ctx.storage.get<SessionState>('session'),
      put: (state) => ctx.storage.put('session', state),
      deleteAll: () => ctx.storage.deleteAll(),
      setAlarm: (at) => ctx.storage.setAlarm(at),
      deleteAlarm: () => ctx.storage.deleteAlarm(),
    };
    this.runner = new SessionRunner(storage, (to, body) => sendText(env, to, body));
  }

  async create(input: CreateInput, token: string): Promise<void> {
    await this.runner.create(input, token);
  }

  async call(token: string, operation: Operation): Promise<CallResult> {
    return this.runner.call(token, operation);
  }

  async alarm(): Promise<void> {
    await this.runner.alarm();
  }
}

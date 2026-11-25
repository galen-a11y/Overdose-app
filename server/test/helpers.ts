// In-memory stand-ins for Durable Objects, Twilio and the clock, so the whole
// API can be exercised end to end in plain Node.

import { handle, type RouterDeps } from '../src/router.ts';
import { SessionRunner, type Storage } from '../src/runner.ts';
import type { SessionState } from '../src/session.ts';
import type { SendResult } from '../src/twilio.ts';

export interface SentText {
  to: string;
  body: string;
  at: number;
}

export class World {
  now = Date.UTC(2026, 10, 25, 20, 0, 0);
  sent: SentText[] = [];
  /** Make the next N sends fail with a retryable error. */
  failNext = 0;
  stores = new Map<string, { state?: SessionState; alarm?: number }>();
  runners = new Map<string, SessionRunner>();
  private ids = 0;

  readonly appKey = 'test-app-key';

  private send = async (to: string, body: string): Promise<SendResult> => {
    if (this.failNext > 0) {
      this.failNext -= 1;
      return { ok: false, retryable: true, status: 503 };
    }
    this.sent.push({ to, body, at: this.now });
    return { ok: true };
  };

  private runner(id: string): SessionRunner {
    let runner = this.runners.get(id);
    if (!runner) {
      const slot: { state?: SessionState; alarm?: number } = {};
      this.stores.set(id, slot);
      const storage: Storage = {
        get: async () => (slot.state ? structuredClone(slot.state) : undefined),
        put: async (state) => {
          slot.state = structuredClone(state);
        },
        deleteAll: async () => {
          slot.state = undefined;
        },
        setAlarm: async (at) => {
          slot.alarm = at;
        },
        deleteAlarm: async () => {
          slot.alarm = undefined;
        },
      };
      runner = new SessionRunner(storage, this.send, () => this.now);
      this.runners.set(id, runner);
    }
    return runner;
  }

  deps(): RouterDeps {
    return {
      appKey: this.appKey,
      sessions: {
        create: (id, input, token) => this.runner(id).create(input, token),
        call: (id, token, op) => this.runner(id).call(token, op),
      },
      send: this.send,
      limit: async () => true,
      now: () => this.now,
      randomId: () => `00000000-0000-4000-8000-${String(++this.ids).padStart(12, '0')}`,
      randomToken: () => `token-${this.ids}`,
    };
  }

  async post(path: string, body: unknown, token?: string, appKey: string = this.appKey) {
    const headers: Record<string, string> = { 'Content-Type': 'application/json', 'X-App-Key': appKey };
    if (token) headers.Authorization = `Bearer ${token}`;
    const response = await handle(new Request(`https://example.test${path}`, { method: 'POST', headers, body: JSON.stringify(body) }), this.deps());
    return { status: response.status, body: (await response.json()) as Record<string, any> };
  }

  /** Moves the clock forward, firing Durable Object alarms as they come due. */
  async advance(ms: number): Promise<void> {
    const end = this.now + ms;
    for (;;) {
      let nextId: string | undefined;
      let nextAt = Infinity;
      for (const [id, slot] of this.stores) {
        if (slot.alarm !== undefined && slot.alarm < nextAt) {
          nextAt = slot.alarm;
          nextId = id;
        }
      }
      if (!nextId || nextAt > end) break;
      this.now = Math.max(this.now, nextAt);
      this.stores.get(nextId)!.alarm = undefined;
      await this.runners.get(nextId)!.alarm();
    }
    this.now = end;
  }
}

export const alice = { name: 'Alice', phone: '+15035550101' };
export const bob = { name: 'Bob', phone: '+15035550102' };
export const here = (at: number) => ({ lat: 45.523064, lon: -122.676483, accuracy: 15, at });

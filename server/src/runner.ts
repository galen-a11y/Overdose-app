// Glue between the pure state machine and storage, timers and Twilio. The
// Durable Object hands this its storage; tests hand it an in-memory fake.

import * as session from './session.ts';
import type { Location, Reason } from './messages.ts';
import type { SendResult } from './twilio.ts';

export interface Storage {
  get(): Promise<session.SessionState | undefined>;
  put(state: session.SessionState): Promise<void>;
  deleteAll(): Promise<void>;
  setAlarm(at: number): Promise<void>;
  deleteAlarm(): Promise<void>;
}

export type Sender = (to: string, body: string) => Promise<SendResult>;

export type Operation =
  | { op: 'heartbeat'; location?: Location }
  | { op: 'checkInStart'; reason: Reason; deadline: number; location?: Location }
  | { op: 'checkInClear'; location?: Location }
  | { op: 'alert'; reason: Reason; location?: Location }
  | { op: 'safe' }
  | { op: 'lowBattery'; location?: Location }
  | { op: 'end' };

export type CallResult = { status: 200 | 401 | 404; body: Record<string, unknown> };

export class SessionRunner {
  private storage: Storage;
  private send: Sender;
  private clock: () => number;

  constructor(storage: Storage, send: Sender, clock: () => number = Date.now) {
    this.storage = storage;
    this.send = send;
    this.clock = clock;
  }

  async create(input: session.CreateInput, token: string): Promise<void> {
    const state = session.createSession(input, token, this.clock());
    await this.commit({ state, actions: [] });
  }

  async call(token: string, operation: Operation): Promise<CallResult> {
    const state = await this.storage.get();
    if (!state) return { status: 404, body: { error: 'session not found or already ended' } };
    if (!timingSafeEqual(token, state.token)) return { status: 401, body: { error: 'bad session token' } };

    const now = this.clock();
    let result: session.Result;
    switch (operation.op) {
      case 'heartbeat':
        result = session.heartbeat(state, now, operation.location);
        break;
      case 'checkInStart':
        result = session.startCheckIn(state, now, operation.reason, operation.deadline, operation.location);
        break;
      case 'checkInClear':
        result = session.clearCheckIn(state, now, operation.location);
        break;
      case 'alert':
        result = session.appAlert(state, now, operation.reason, operation.location);
        break;
      case 'safe':
        result = session.markSafe(state, now);
        break;
      case 'lowBattery':
        result = session.lowBattery(state, now, operation.location);
        break;
      case 'end':
        result = session.endSession(state);
        break;
    }
    const sent = await this.commit(result);
    return { status: 200, body: { ok: true, textsSent: sent, alertSent: result.state.alert !== undefined } };
  }

  async alarm(): Promise<void> {
    const state = await this.storage.get();
    if (!state) return;
    await this.commit(session.onAlarm(state, this.clock()));
  }

  /** Saves state first, then sends, then saves retries for anything that failed. */
  private async commit(result: session.Result): Promise<number> {
    if (result.delete) {
      await this.storage.deleteAlarm();
      await this.storage.deleteAll();
      // A final "I'm safe" text still goes out; there is just nothing left to retry it from.
      const outcomes = await Promise.all(result.actions.map((a) => this.send(a.to, a.body)));
      return outcomes.filter((o) => o.ok).length;
    }

    await this.storage.put(result.state);
    await this.storage.setAlarm(session.nextAlarmAt(result.state));
    if (result.actions.length === 0) return 0;

    const outcomes = await Promise.all(result.actions.map((a) => this.send(a.to, a.body)));
    const failed = result.actions.filter((_, i) => {
      const outcome = outcomes[i];
      return !outcome.ok && outcome.retryable;
    });
    if (failed.length > 0) {
      const withRetries = session.scheduleRetries(result.state, failed, this.clock());
      await this.storage.put(withRetries);
      await this.storage.setAlarm(session.nextAlarmAt(withRetries));
    }
    return outcomes.filter((o) => o.ok).length;
  }
}

export function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

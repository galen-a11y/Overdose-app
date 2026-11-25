// The session state machine that runs inside each Durable Object. Pure
// functions with injected time, so every path is unit tested without Cloudflare.
//
// The server is the backup for everything the phone can't do once it goes quiet:
// - heartbeat stops for ~2 minutes      -> softer "lost contact" text
// - a check-in starts and no "I'm OK" or alert arrives by the deadline -> alert text
// - an alert went out and no "I'm safe" for 5 minutes -> follow-up text

import { buildMessage, type Location, type MessageKind, type Reason } from './messages.ts';

export interface Contact {
  name: string;
  phone: string;
}

export interface PendingText {
  to: string;
  body: string;
  kind: MessageKind;
  attempts: number;
  nextAttemptAt: number;
}

export interface SessionState {
  firstName: string;
  contacts: Contact[];
  timeZone: string;
  token: string;
  createdAt: number;
  expiresAt: number;
  heartbeatTimeoutMs: number;
  lastHeartbeatAt: number;
  location?: Location;
  /** Set while the phone is showing a check-in. The deadline includes a grace period. */
  checkIn?: { reason: Reason; deadline: number };
  alert?: { reason?: Reason; sentAt: number; source: 'app' | 'server'; followUpSentAt?: number };
  lostContactSentAt?: number;
  lowBatterySentAt?: number;
  safeSentAt?: number;
  textsSent: number;
  /** Texts Twilio refused or that failed to reach Twilio, retried by the alarm. */
  retries: PendingText[];
}

export interface SmsAction {
  type: 'sms';
  to: string;
  body: string;
  kind: MessageKind;
  attempts: number;
}

export interface Result {
  state: SessionState;
  actions: SmsAction[];
  /** True when the session is over and its storage should be wiped. */
  delete?: boolean;
}

export const LIMITS = {
  maxContacts: 3,
  maxTextsPerSession: 40,
  minHeartbeatTimeoutMs: 60_000,
  maxHeartbeatTimeoutMs: 600_000,
  defaultHeartbeatTimeoutMs: 120_000,
  maxSessionMs: 12 * 60 * 60 * 1000,
  /** Extra time the server waits past the app's check-in deadline before alerting on its own. */
  checkInGraceMs: 20_000,
  followUpDelayMs: 5 * 60 * 1000,
  /** Keep a session around this long after its planned end, so the backup still works if the person forgets to end it. */
  sessionTailMs: 60 * 60 * 1000,
  maxCheckInDeadlineMs: 5 * 60 * 1000,
  maxTextAttempts: 6,
};

export interface CreateInput {
  firstName: string;
  contacts: Contact[];
  timeZone?: string;
  heartbeatTimeoutSec?: number;
  plannedDurationSec?: number;
  location?: Location;
}

export function createSession(input: CreateInput, token: string, now: number): SessionState {
  const heartbeatTimeoutMs = clamp(
    (input.heartbeatTimeoutSec ?? LIMITS.defaultHeartbeatTimeoutMs / 1000) * 1000,
    LIMITS.minHeartbeatTimeoutMs,
    LIMITS.maxHeartbeatTimeoutMs,
  );
  const planned = input.plannedDurationSec ? input.plannedDurationSec * 1000 + LIMITS.sessionTailMs : LIMITS.maxSessionMs;
  return {
    firstName: input.firstName,
    contacts: input.contacts.slice(0, LIMITS.maxContacts),
    timeZone: input.timeZone ?? 'UTC',
    token,
    createdAt: now,
    expiresAt: now + Math.min(planned, LIMITS.maxSessionMs),
    heartbeatTimeoutMs,
    lastHeartbeatAt: now,
    location: input.location,
    textsSent: 0,
    retries: [],
  };
}

// MARK: - Events from the app

export function heartbeat(state: SessionState, now: number, location?: Location): Result {
  const next = touch(state, now, location);
  const actions: SmsAction[] = [];
  // The phone came back after we told contacts it went quiet. Tell them, but
  // never in a way that sounds like "all clear".
  if (next.lostContactSentAt !== undefined && !next.alert) {
    next.lostContactSentAt = undefined;
    actions.push(...textAll(next, 'reconnected', now));
  }
  return { state: next, actions };
}

export function startCheckIn(state: SessionState, now: number, reason: Reason, appDeadline: number, location?: Location): Result {
  const next = touch(state, now, location);
  const deadline = clamp(appDeadline, now, now + LIMITS.maxCheckInDeadlineMs) + LIMITS.checkInGraceMs;
  if (!next.alert) next.checkIn = { reason, deadline };
  return { state: next, actions: [] };
}

export function clearCheckIn(state: SessionState, now: number, location?: Location): Result {
  const next = touch(state, now, location);
  next.checkIn = undefined;
  return { state: next, actions: [] };
}

/** The app's countdown ran out. Safe to call more than once: only the first sends. */
export function appAlert(state: SessionState, now: number, reason: Reason, location?: Location): Result {
  const next = touch(state, now, location);
  return sendAlert(next, now, reason, 'app');
}

/** "I'm safe now". Tells contacts only if they were told something was wrong. Ends the session. */
export function markSafe(state: SessionState, now: number): Result {
  const next = clone(state);
  const actions: SmsAction[] = [];
  const contactsWorried = next.alert !== undefined || next.lostContactSentAt !== undefined || next.lowBatterySentAt !== undefined;
  if (contactsWorried && next.safeSentAt === undefined) {
    next.safeSentAt = now;
    actions.push(...textAll(next, 'safe', now));
  }
  return { state: next, actions, delete: true };
}

export function lowBattery(state: SessionState, now: number, location?: Location): Result {
  const next = touch(state, now, location);
  if (next.lowBatterySentAt !== undefined || next.alert) return { state: next, actions: [] };
  next.lowBatterySentAt = now;
  return { state: next, actions: textAll(next, 'lowBattery', now) };
}

export function endSession(state: SessionState): Result {
  return { state, actions: [], delete: true };
}

// MARK: - Timer

/** Runs whatever is due. Called from the Durable Object alarm. */
export function onAlarm(state: SessionState, now: number): Result {
  let next = clone(state);
  const actions: SmsAction[] = [];

  // Retry texts that failed earlier.
  const due = next.retries.filter((t) => t.nextAttemptAt <= now);
  next.retries = next.retries.filter((t) => t.nextAttemptAt > now);
  actions.push(...due.map((t) => ({ type: 'sms' as const, to: t.to, body: t.body, kind: t.kind, attempts: t.attempts })));

  if (now >= next.expiresAt) {
    return { state: next, actions, delete: true };
  }

  if (next.checkIn && now >= next.checkIn.deadline && !next.alert) {
    const result = sendAlert(next, now, next.checkIn.reason, 'server');
    next = result.state;
    actions.push(...result.actions);
  }

  if (next.alert && next.alert.followUpSentAt === undefined && next.safeSentAt === undefined && now >= next.alert.sentAt + LIMITS.followUpDelayMs) {
    next.alert.followUpSentAt = now;
    actions.push(...textAll(next, 'followUp', now));
  }

  const silentFor = now - next.lastHeartbeatAt;
  if (!next.alert && !next.checkIn && next.lostContactSentAt === undefined && silentFor >= next.heartbeatTimeoutMs) {
    next.lostContactSentAt = now;
    actions.push(...textAll(next, 'lostContact', now));
  }

  return { state: next, actions };
}

/** When the Durable Object alarm should next fire. */
export function nextAlarmAt(state: SessionState): number {
  const times: number[] = [state.expiresAt];
  if (state.checkIn && !state.alert) times.push(state.checkIn.deadline);
  if (state.alert && state.alert.followUpSentAt === undefined && state.safeSentAt === undefined) {
    times.push(state.alert.sentAt + LIMITS.followUpDelayMs);
  }
  if (!state.alert && !state.checkIn && state.lostContactSentAt === undefined) {
    times.push(state.lastHeartbeatAt + state.heartbeatTimeoutMs);
  }
  for (const retry of state.retries) times.push(retry.nextAttemptAt);
  return Math.min(...times);
}

/** Puts texts that failed back on the retry list with backoff, up to a limit. */
export function scheduleRetries(state: SessionState, failed: SmsAction[], now: number): SessionState {
  const next = clone(state);
  for (const text of failed) {
    const attempts = text.attempts + 1;
    if (attempts >= LIMITS.maxTextAttempts) continue;
    next.retries.push({ to: text.to, body: text.body, kind: text.kind, attempts, nextAttemptAt: now + Math.min(60_000, 5_000 * 2 ** (attempts - 1)) });
  }
  return next;
}

// MARK: - Helpers

function sendAlert(state: SessionState, now: number, reason: Reason, source: 'app' | 'server'): Result {
  if (state.alert) return { state, actions: [] };
  state.alert = { reason, sentAt: now, source };
  state.checkIn = undefined;
  return { state, actions: textAll(state, 'alert', now, reason) };
}

function textAll(state: SessionState, kind: MessageKind, now: number, reason?: Reason): SmsAction[] {
  const actions: SmsAction[] = [];
  for (const contact of state.contacts) {
    if (state.textsSent >= LIMITS.maxTextsPerSession) break;
    state.textsSent += 1;
    const body = buildMessage(kind, {
      firstName: state.firstName,
      timeZone: state.timeZone,
      location: state.location,
      now,
      contactName: contact.name,
      reason,
    });
    actions.push({ type: 'sms', to: contact.phone, body, kind, attempts: 0 });
  }
  return actions;
}

function touch(state: SessionState, now: number, location?: Location): SessionState {
  const next = clone(state);
  next.lastHeartbeatAt = Math.max(next.lastHeartbeatAt, now);
  if (location && (!next.location || location.at >= next.location.at)) next.location = location;
  return next;
}

function clone(state: SessionState): SessionState {
  return structuredClone(state);
}

function clamp(value: number, min: number, max: number): number {
  return Math.min(Math.max(value, min), max);
}

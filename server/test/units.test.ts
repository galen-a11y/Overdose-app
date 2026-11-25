import assert from 'node:assert/strict';
import { describe, it } from 'node:test';
import { buildMessage, formatTime, mapLink } from '../src/messages.ts';
import { createSession, nextAlarmAt, onAlarm, LIMITS } from '../src/session.ts';
import { maskPhone, sendText } from '../src/twilio.ts';
import { alice, bob, here } from './helpers.ts';

const t0 = Date.UTC(2026, 10, 25, 20, 0, 0);

describe('messages', () => {
  it('formats time in the person\'s time zone', () => {
    assert.equal(formatTime(t0, 'America/New_York'), '3:00 PM EST');
    assert.equal(formatTime(t0, 'Not/AZone'), '8:00 PM UTC');
  });

  it('builds a map link', () => {
    assert.equal(mapLink({ lat: 45.1234567, lon: -122.7654321, at: t0 }), 'https://maps.google.com/?q=45.12346,-122.76543');
  });

  it('flags stale and approximate locations, and handles none', () => {
    const stale = buildMessage('alert', { firstName: 'Sam', timeZone: 'UTC', now: t0, location: { lat: 1, lon: 2, accuracy: 500, at: t0 - 20 * 60_000 } });
    assert.match(stale, /Location \(approximate\):.*\(may be out of date\)/);
    const none = buildMessage('alert', { firstName: 'Sam', timeZone: 'UTC', now: t0 });
    assert.match(none, /Location: not available\./);
  });

  it('keeps every message short enough for a few SMS segments and never mentions drugs', () => {
    const kinds = ['welcome', 'test', 'alert', 'followUp', 'lostContact', 'reconnected', 'safe', 'lowBattery'] as const;
    for (const kind of kinds) {
      const body = buildMessage(kind, { firstName: 'Samantha-Jo', timeZone: 'America/Los_Angeles', now: t0, location: here(t0), contactName: 'Alexander', reason: 'signalLost' });
      assert.ok(body.length <= 320, `${kind} is ${body.length} chars`);
      assert.doesNotMatch(body, /drug|overdose|opioid|fentanyl|narcan|naloxone/i, kind);
    }
  });
});

describe('session timers', () => {
  it('schedules the heartbeat deadline, then the check-in deadline, then the follow-up', () => {
    let s = createSession({ firstName: 'Sam', contacts: [alice, bob] }, 'tok', t0);
    assert.equal(nextAlarmAt(s), t0 + LIMITS.defaultHeartbeatTimeoutMs);
    s = { ...s, checkIn: { reason: 'lowOxygen', deadline: t0 + 50_000 } };
    assert.equal(nextAlarmAt(s), t0 + 50_000);
    const fired = onAlarm(s, t0 + 50_000);
    assert.equal(fired.actions.length, 2);
    assert.equal(nextAlarmAt(fired.state), t0 + 50_000 + LIMITS.followUpDelayMs);
  });

  it('clamps the heartbeat timeout', () => {
    assert.equal(createSession({ firstName: 'S', contacts: [alice], heartbeatTimeoutSec: 1 }, 't', t0).heartbeatTimeoutMs, 60_000);
    assert.equal(createSession({ firstName: 'S', contacts: [alice], heartbeatTimeoutSec: 99_999 }, 't', t0).heartbeatTimeoutMs, 600_000);
  });

  it('caps texts per session', () => {
    let s = createSession({ firstName: 'Sam', contacts: [alice, bob] }, 'tok', t0);
    s = { ...s, textsSent: LIMITS.maxTextsPerSession - 1 };
    const r = onAlarm(s, t0 + LIMITS.defaultHeartbeatTimeoutMs);
    assert.equal(r.actions.length, 1);
  });
});

describe('twilio', () => {
  it('masks phone numbers for logs', () => {
    assert.equal(maskPhone('+15035550101'), '+1******01');
  });

  it('posts a form to the Messages API with basic auth', async () => {
    let captured: { url: string; init: RequestInit } | undefined;
    const fakeFetch = async (url: string, init: RequestInit) => {
      captured = { url, init };
      return new Response('{}', { status: 201 });
    };
    const result = await sendText({ TWILIO_ACCOUNT_SID: 'AC123', TWILIO_AUTH_TOKEN: 'secret', TWILIO_FROM: '+15035550000' }, '+15035550101', 'hello', fakeFetch);
    assert.deepEqual(result, { ok: true });
    assert.equal(captured!.url, 'https://api.twilio.com/2010-04-01/Accounts/AC123/Messages.json');
    assert.equal((captured!.init.headers as Record<string, string>).Authorization, `Basic ${btoa('AC123:secret')}`);
    const form = new URLSearchParams(captured!.init.body as string);
    assert.equal(form.get('To'), '+15035550101');
    assert.equal(form.get('From'), '+15035550000');
    assert.equal(form.get('Body'), 'hello');
  });

  it('treats 5xx and 429 as retryable, 4xx as final', async () => {
    const config = { TWILIO_ACCOUNT_SID: 'AC1', TWILIO_AUTH_TOKEN: 's', TWILIO_MESSAGING_SERVICE_SID: 'MG1' };
    const status = (code: number) => async () => new Response('{}', { status: code });
    assert.deepEqual(await sendText(config, '+15035550101', 'x', status(503)), { ok: false, retryable: true, status: 503 });
    assert.deepEqual(await sendText(config, '+15035550101', 'x', status(429)), { ok: false, retryable: true, status: 429 });
    assert.deepEqual(await sendText(config, '+15035550101', 'x', status(400)), { ok: false, retryable: false, status: 400 });
  });

  it('does not send in dry run', async () => {
    const result = await sendText({ DRY_RUN: 'true' }, '+15035550101', 'x', async () => {
      throw new Error('should not be called');
    });
    assert.deepEqual(result, { ok: true });
  });
});

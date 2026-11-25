import assert from 'node:assert/strict';
import { beforeEach, describe, it } from 'node:test';
import { alice, bob, here, World } from './helpers.ts';

let world: World;

async function startSession(extra: Record<string, unknown> = {}) {
  const res = await world.post('/v1/sessions', {
    firstName: 'Sam',
    contacts: [alice, bob],
    timeZone: 'America/Los_Angeles',
    location: here(world.now),
    ...extra,
  });
  assert.equal(res.status, 200);
  const { sessionId, token } = res.body;
  const call = (route: string, body: unknown = {}) => world.post(`/v1/sessions/${sessionId}/${route}`, body, token);
  return { sessionId, token, call };
}

/** Sends a heartbeat every 20 s for the given duration, like the app does. */
async function heartbeatFor(call: (r: string, b?: unknown) => Promise<unknown>, ms: number) {
  const end = world.now + ms;
  while (world.now + 20_000 <= end) {
    await world.advance(20_000);
    await call('heartbeat', { location: here(world.now) });
  }
  await world.advance(end - world.now);
}

beforeEach(() => {
  world = new World();
});

describe('auth and validation', () => {
  it('rejects a wrong app key', async () => {
    const res = await world.post('/v1/sessions', {}, undefined, 'wrong');
    assert.equal(res.status, 401);
  });

  it('rejects bad input without echoing it', async () => {
    const res = await world.post('/v1/sessions', { firstName: 'Sam', contacts: [{ name: 'A', phone: '5035550101' }] });
    assert.equal(res.status, 400);
    assert.match(res.body.error, /E\.164/);
  });

  it('rejects more than three contacts', async () => {
    const contacts = [1, 2, 3, 4].map((i) => ({ name: `C${i}`, phone: `+1503555010${i}` }));
    const res = await world.post('/v1/sessions', { firstName: 'Sam', contacts });
    assert.equal(res.status, 400);
  });

  it('rejects a wrong session token', async () => {
    const { sessionId } = await startSession();
    const res = await world.post(`/v1/sessions/${sessionId}/heartbeat`, {}, 'not-the-token');
    assert.equal(res.status, 401);
  });

  it('strips links and symbols out of the first name', async () => {
    await world.post('/v1/test', { firstName: 'Sam http://evil.example', contacts: [alice] });
    assert.doesNotMatch(world.sent[0].body, /evil\.example/);
    assert.doesNotMatch(world.sent[0].body, /http:/);
  });
});

describe('setup texts', () => {
  it('sends a clearly labeled test to each contact', async () => {
    const res = await world.post('/v1/test', { firstName: 'Sam', contacts: [alice, bob] });
    assert.equal(res.status, 200);
    assert.deepEqual(res.body.results.map((r: any) => r.sent), [true, true]);
    assert.equal(world.sent.length, 2);
    assert.match(world.sent[0].body, /^TEST from Sam's safety app/);
  });

  it('sends a welcome text explaining what an alert means', async () => {
    await world.post('/v1/welcome', { firstName: 'Sam', contact: alice });
    assert.equal(world.sent.length, 1);
    assert.match(world.sent[0].body, /Hi Alice, Sam added you as an emergency contact/);
    assert.match(world.sent[0].body, /Reply STOP/);
  });
});

describe('a normal session', () => {
  it('sends nothing while heartbeats keep coming, and forgets everything at the end', async () => {
    const { sessionId, call } = await startSession();
    await heartbeatFor(call, 60 * 60 * 1000);
    assert.equal(world.sent.length, 0);
    const end = await call('end');
    assert.equal(end.status, 200);
    assert.equal(world.stores.get(sessionId)!.state, undefined);
    assert.equal(world.stores.get(sessionId)!.alarm, undefined);
    const after = await call('heartbeat');
    assert.equal(after.status, 404);
  });
});

describe('heartbeat backup', () => {
  it('texts a softer lost-contact message after about 2 minutes of silence', async () => {
    const { call } = await startSession();
    await heartbeatFor(call, 60_000);
    const lastBeat = world.now;
    await world.advance(119_000);
    assert.equal(world.sent.length, 0);
    await world.advance(2_000);
    assert.equal(world.sent.length, 2);
    assert.equal(world.sent[0].at, lastBeat + 120_000);
    assert.match(world.sent[0].body, /^Sam's safety app lost contact\. Please check on them\./);
    assert.match(world.sent[0].body, /maps\.google\.com\/\?q=45\.52306,-122\.67648/);
    // Only once.
    await world.advance(30 * 60_000);
    assert.equal(world.sent.length, 2);
  });

  it('tells contacts when the app is back, without sounding like all clear', async () => {
    const { call } = await startSession();
    await world.advance(130_000);
    assert.equal(world.sent.length, 2);
    await call('heartbeat', { location: here(world.now) });
    assert.equal(world.sent.length, 4);
    assert.match(world.sent[2].body, /back in contact.*please still check on them/);
  });
});

describe('check-in and alert', () => {
  it('sends the alert when the app reports the countdown ran out, only once', async () => {
    const { call } = await startSession();
    await heartbeatFor(call, 40_000);
    await call('check-in', { reason: 'lowOxygen', deadline: world.now + 30_000 });
    await world.advance(30_000);
    const res = await call('alert', { reason: 'lowOxygen', location: here(world.now) });
    assert.equal(res.body.alertSent, true);
    await call('alert', { reason: 'lowOxygen' });
    assert.equal(world.sent.length, 2);
    assert.match(world.sent[0].body, /^Sam may need help\. Their safety app detected a low oxygen reading/);
    assert.match(world.sent[0].body, /call 911/);
    assert.doesNotMatch(world.sent[0].body, /drug|overdose|opioid/i);
  });

  it('sends the alert itself if the phone goes quiet mid check-in', async () => {
    const { call } = await startSession();
    const deadline = world.now + 30_000;
    await call('check-in', { reason: 'signalLost', deadline });
    await world.advance(49_000);
    assert.equal(world.sent.length, 0, 'waits out a grace period past the app deadline');
    await world.advance(2_000);
    assert.equal(world.sent.length, 2);
    assert.match(world.sent[0].body, /lost its sensor signal/);
  });

  it('does nothing when the person taps I am OK', async () => {
    const { call } = await startSession();
    await call('check-in', { reason: 'lowOxygen', deadline: world.now + 30_000 });
    await world.advance(10_000);
    await call('check-in/clear');
    await heartbeatFor(call, 10 * 60_000);
    assert.equal(world.sent.length, 0);
  });

  it('follows up after 5 minutes if nobody taps I am safe now', async () => {
    const { call } = await startSession();
    await call('alert', { reason: 'lowOxygen', location: here(world.now) });
    await heartbeatFor(call, 4 * 60_000 + 50_000);
    assert.equal(world.sent.length, 2);
    await heartbeatFor(call, 20_000);
    assert.equal(world.sent.length, 4);
    assert.match(world.sent[2].body, /^Still no response from Sam/);
    // No lost-contact text on top of an alert.
    await world.advance(60 * 60_000);
    assert.equal(world.sent.length, 4);
  });

  it('I am safe now tells contacts and ends the session', async () => {
    const { sessionId, call } = await startSession();
    await call('alert', { reason: 'signalLost' });
    await world.advance(60_000);
    await call('safe');
    assert.equal(world.sent.length, 4);
    assert.match(world.sent[3].body, /Sam says they're safe now/);
    assert.equal(world.stores.get(sessionId)!.state, undefined);
    await world.advance(10 * 60_000);
    assert.equal(world.sent.length, 4, 'no follow-up after safe');
  });

  it('I am safe now sends nothing if contacts were never worried', async () => {
    const { call } = await startSession();
    await call('safe');
    assert.equal(world.sent.length, 0);
  });

  it('retries texts that fail to send', async () => {
    const { call } = await startSession();
    world.failNext = 2;
    await call('alert', { reason: 'lowOxygen' });
    assert.equal(world.sent.length, 0);
    await world.advance(6_000);
    assert.equal(world.sent.length, 2);
    assert.match(world.sent[0].body, /may need help/);
  });
});

describe('phone battery and session lifetime', () => {
  it('warns contacts once when the phone is about to die', async () => {
    const { call } = await startSession();
    await call('low-battery', { location: here(world.now) });
    await call('low-battery');
    assert.equal(world.sent.length, 2);
    assert.match(world.sent[0].body, /battery is almost dead/);
  });

  it('deletes a forgotten session an hour after its planned end', async () => {
    const { sessionId, call } = await startSession({ plannedDurationSec: 3600 });
    await heartbeatFor(call, 2 * 60 * 60_000 + 20_000);
    assert.equal(world.stores.get(sessionId)!.state, undefined);
  });
});

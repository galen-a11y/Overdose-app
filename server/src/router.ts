// HTTP API used by the app. Every route is POST with a JSON body.
//
//   POST /v1/sessions                        start a session -> { sessionId, token }
//   POST /v1/sessions/:id/heartbeat          every 15-30 s during a session
//   POST /v1/sessions/:id/check-in           a check-in started on the phone
//   POST /v1/sessions/:id/check-in/clear     the person tapped "I'm OK"
//   POST /v1/sessions/:id/alert              the countdown ran out
//   POST /v1/sessions/:id/safe               "I'm safe now"; ends the session
//   POST /v1/sessions/:id/low-battery        phone is about to die
//   POST /v1/sessions/:id/end                ends the session, deletes everything
//   POST /v1/test                            setup test text to each contact
//   POST /v1/welcome                         "you've been added" text to one contact
//
// Session routes need `Authorization: Bearer <token>`. Every route needs
// `X-App-Key` when APP_KEY is configured.

import { buildMessage } from './messages.ts';
import type { CallResult, Operation, Sender } from './runner.ts';
import { timingSafeEqual } from './runner.ts';
import type { CreateInput } from './session.ts';
import * as v from './validate.ts';

export interface RouterDeps {
  appKey?: string;
  sessions: {
    create(id: string, input: CreateInput, token: string): Promise<void>;
    call(id: string, token: string, operation: Operation): Promise<CallResult>;
  };
  send: Sender;
  /** Returns false when the key is over its rate limit. */
  limit(key: string): Promise<boolean>;
  now(): number;
  randomId(): string;
  randomToken(): string;
}

const SESSION_ID = /^[0-9a-f-]{36}$/;

export async function handle(request: Request, deps: RouterDeps): Promise<Response> {
  try {
    const url = new URL(request.url);
    if (request.method === 'GET' && url.pathname === '/health') return json(200, { ok: true });
    if (request.method !== 'POST') return json(405, { error: 'POST only' });
    if (deps.appKey && !timingSafeEqual(request.headers.get('X-App-Key') ?? '', deps.appKey)) {
      return json(401, { error: 'bad app key' });
    }

    const body = await readBody(request);
    const parts = url.pathname.split('/').filter(Boolean);

    if (parts.length === 2 && parts[0] === 'v1' && parts[1] === 'sessions') {
      const input = v.createInput(body);
      const id = deps.randomId();
      const token = deps.randomToken();
      await deps.sessions.create(id, input, token);
      return json(200, { sessionId: id, token });
    }

    if (parts.length === 2 && parts[0] === 'v1' && parts[1] === 'test') {
      return sendSetupTexts(deps, 'test', v.firstName(body.firstName), v.contacts(body.contacts));
    }

    if (parts.length === 2 && parts[0] === 'v1' && parts[1] === 'welcome') {
      return sendSetupTexts(deps, 'welcome', v.firstName(body.firstName), [v.contact(body.contact)]);
    }

    if (parts.length >= 4 && parts[0] === 'v1' && parts[1] === 'sessions' && SESSION_ID.test(parts[2])) {
      const token = (request.headers.get('Authorization') ?? '').replace(/^Bearer /, '');
      if (!token) return json(401, { error: 'missing session token' });
      const operation = sessionOperation(parts.slice(3).join('/'), body);
      if (!operation) return json(404, { error: 'unknown route' });
      const result = await deps.sessions.call(parts[2], token, operation);
      return json(result.status, result.body);
    }

    return json(404, { error: 'unknown route' });
  } catch (error) {
    if (error instanceof v.BadRequest) return json(400, { error: error.message });
    console.error(`Unhandled error: ${(error as Error).message}`);
    return json(500, { error: 'server error' });
  }
}

function sessionOperation(route: string, body: Record<string, unknown>): Operation | undefined {
  const location = v.location(body.location);
  switch (route) {
    case 'heartbeat':
      return { op: 'heartbeat', location };
    case 'check-in':
      return { op: 'checkInStart', reason: v.reason(body.reason), deadline: v.epochMs(body.deadline, 'deadline'), location };
    case 'check-in/clear':
      return { op: 'checkInClear', location };
    case 'alert':
      return { op: 'alert', reason: v.reason(body.reason), location };
    case 'safe':
      return { op: 'safe' };
    case 'low-battery':
      return { op: 'lowBattery', location };
    case 'end':
      return { op: 'end' };
    default:
      return undefined;
  }
}

async function sendSetupTexts(
  deps: RouterDeps,
  kind: 'test' | 'welcome',
  firstName: string,
  contacts: { name: string; phone: string }[],
): Promise<Response> {
  const results: { phone: string; sent: boolean; error?: string }[] = [];
  for (const contact of contacts) {
    if (!(await deps.limit(`${kind}:${contact.phone}`))) {
      results.push({ phone: contact.phone, sent: false, error: 'rate limited, try again in a minute' });
      continue;
    }
    const body = buildMessage(kind, { firstName, timeZone: 'UTC', now: deps.now(), contactName: contact.name });
    const outcome = await deps.send(contact.phone, body);
    results.push({ phone: contact.phone, sent: outcome.ok, error: outcome.ok ? undefined : 'text could not be sent' });
  }
  return json(200, { results });
}

async function readBody(request: Request): Promise<Record<string, unknown>> {
  const text = await request.text();
  if (text.length > 8_192) throw new v.BadRequest('body too large');
  if (!text) return {};
  try {
    const parsed = JSON.parse(text);
    if (parsed && typeof parsed === 'object' && !Array.isArray(parsed)) return parsed as Record<string, unknown>;
  } catch {
    // fall through
  }
  throw new v.BadRequest('body must be a JSON object');
}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });
}

// Input checking for every endpoint. Anything unexpected is rejected rather
// than guessed at, and nothing here logs names or numbers.

import type { Location, Reason } from './messages.ts';
import { LIMITS, type Contact, type CreateInput } from './session.ts';

export class BadRequest extends Error {}

const E164 = /^\+[1-9]\d{7,14}$/;

export function firstName(value: unknown): string {
  if (typeof value !== 'string') throw new BadRequest('firstName is required');
  const cleaned = safeName(value);
  if (!cleaned) throw new BadRequest('firstName is required');
  return cleaned;
}

export function contact(value: unknown): Contact {
  if (!value || typeof value !== 'object') throw new BadRequest('contact is invalid');
  const v = value as Record<string, unknown>;
  if (typeof v.phone !== 'string' || !E164.test(v.phone)) throw new BadRequest('contact phone must be E.164');
  const name = typeof v.name === 'string' ? safeName(v.name) : '';
  return { name: name || 'there', phone: v.phone };
}

export function contacts(value: unknown): Contact[] {
  if (!Array.isArray(value) || value.length === 0) throw new BadRequest('at least one contact is required');
  if (value.length > LIMITS.maxContacts) throw new BadRequest(`at most ${LIMITS.maxContacts} contacts`);
  const list = value.map(contact);
  if (new Set(list.map((c) => c.phone)).size !== list.length) throw new BadRequest('duplicate contact phone');
  return list;
}

export function location(value: unknown): Location | undefined {
  if (value === undefined || value === null) return undefined;
  if (typeof value !== 'object') throw new BadRequest('location is invalid');
  const v = value as Record<string, unknown>;
  const lat = Number(v.lat);
  const lon = Number(v.lon);
  const at = Number(v.at);
  if (!Number.isFinite(lat) || lat < -90 || lat > 90) throw new BadRequest('location.lat is invalid');
  if (!Number.isFinite(lon) || lon < -180 || lon > 180) throw new BadRequest('location.lon is invalid');
  if (!Number.isFinite(at) || at <= 0) throw new BadRequest('location.at is invalid');
  const accuracy = v.accuracy === undefined ? undefined : Number(v.accuracy);
  return { lat, lon, at, accuracy: Number.isFinite(accuracy) ? accuracy : undefined };
}

export function reason(value: unknown): Reason {
  if (value === 'lowOxygen' || value === 'signalLost') return value;
  throw new BadRequest('reason must be lowOxygen or signalLost');
}

export function timeZone(value: unknown): string {
  if (typeof value !== 'string' || value.length > 64) return 'UTC';
  try {
    new Intl.DateTimeFormat('en-US', { timeZone: value });
    return value;
  } catch {
    return 'UTC';
  }
}

export function epochMs(value: unknown, field: string): number {
  const n = Number(value);
  if (!Number.isFinite(n) || n <= 0) throw new BadRequest(`${field} is invalid`);
  return n;
}

export function createInput(body: Record<string, unknown>): CreateInput {
  const optionalNumber = (v: unknown) => (v === undefined || v === null ? undefined : Number.isFinite(Number(v)) ? Number(v) : undefined);
  return {
    firstName: firstName(body.firstName),
    contacts: contacts(body.contacts),
    timeZone: timeZone(body.timeZone),
    heartbeatTimeoutSec: optionalNumber(body.heartbeatTimeoutSec),
    plannedDurationSec: optionalNumber(body.plannedDurationSec),
    location: location(body.location),
  };
}

/**
 * Letters, spaces, apostrophes and hyphens only, so a name can't smuggle a
 * link or other text into a message sent from our number. No periods, so
 * "evil.example" can't become a tappable domain.
 */
function safeName(value: string): string {
  return value.normalize('NFC').replace(/[^\p{L}\p{M} '-]/gu, '').replace(/\s+/g, ' ').trim().slice(0, 30);
}

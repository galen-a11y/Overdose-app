// Every text the service sends. Rules from docs/SPEC.md: first name only,
// say the person "may need help", give the location, never mention drugs.

export type Reason = 'lowOxygen' | 'signalLost';

export type MessageKind =
  | 'welcome'
  | 'test'
  | 'alert'
  | 'followUp'
  | 'lostContact'
  | 'reconnected'
  | 'safe'
  | 'lowBattery';

export interface Location {
  lat: number;
  lon: number;
  /** Horizontal accuracy in meters, if known. */
  accuracy?: number;
  /** When the phone took this fix, in epoch milliseconds. */
  at: number;
}

export interface MessageContext {
  firstName: string;
  timeZone: string;
  location?: Location;
  now: number;
  contactName?: string;
  reason?: Reason;
}

export function mapLink(location: Location): string {
  const lat = location.lat.toFixed(5);
  const lon = location.lon.toFixed(5);
  return `https://maps.google.com/?q=${lat},${lon}`;
}

export function formatTime(epochMs: number, timeZone: string): string {
  const options: Intl.DateTimeFormatOptions = { hour: 'numeric', minute: '2-digit', timeZoneName: 'short' };
  try {
    return new Intl.DateTimeFormat('en-US', { ...options, timeZone }).format(epochMs);
  } catch {
    return new Intl.DateTimeFormat('en-US', { ...options, timeZone: 'UTC' }).format(epochMs);
  }
}

function locationLine(ctx: MessageContext, label = 'Location'): string {
  if (!ctx.location) return `${label}: not available.`;
  const age = ctx.now - ctx.location.at;
  const when = formatTime(ctx.location.at, ctx.timeZone);
  const stale = age > 10 * 60 * 1000 ? ' (may be out of date)' : '';
  const approx = ctx.location.accuracy !== undefined && ctx.location.accuracy > 200 ? ' (approximate)' : '';
  return `${label}${approx}: ${mapLink(ctx.location)} as of ${when}${stale}.`;
}

function trigger(reason: Reason | undefined): string {
  switch (reason) {
    case 'lowOxygen':
      return 'Their safety app detected a low oxygen reading and they did not respond to a check-in.';
    case 'signalLost':
      return 'Their safety app lost its sensor signal and they did not respond to a check-in.';
    default:
      return 'They did not respond to a check-in from their safety app.';
  }
}

export function buildMessage(kind: MessageKind, ctx: MessageContext): string {
  const name = ctx.firstName;
  const now = formatTime(ctx.now, ctx.timeZone);
  switch (kind) {
    case 'welcome':
      return (
        `Hi ${ctx.contactName ?? 'there'}, ${name} added you as an emergency contact in their safety app. ` +
        `If they ever don't respond to a check-in, you'll get a text from this number with their location. ` +
        `If that happens, please go check on them or call 911. Reply STOP to opt out.`
      );
    case 'test':
      return (
        `TEST from ${name}'s safety app. This is only a test, no action needed. ` +
        `A real alert would say ${name} may need help and include their location.`
      );
    case 'alert':
      return `${name} may need help. ${trigger(ctx.reason)} ${locationLine(ctx)} Sent ${now}. Please check on them now or call 911.`;
    case 'followUp':
      return `Still no response from ${name}. ${locationLine(ctx, 'Last known location')} Please check on them now or call 911.`;
    case 'lostContact':
      return `${name}'s safety app lost contact. Please check on them. ${locationLine(ctx, 'Last known location')}`;
    case 'reconnected':
      return `${name}'s safety app is back in contact (${now}). If you haven't reached them yet, please still check on them.`;
    case 'safe':
      return `${name} says they're safe now (${now}). Thank you for being there.`;
    case 'lowBattery':
      return `${name}'s phone battery is almost dead, so their safety app may stop working soon. Please check on them. ${locationLine(ctx, 'Last known location')}`;
  }
}

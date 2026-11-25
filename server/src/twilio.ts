// Sends one text through Twilio's Messages API.

export interface TwilioConfig {
  TWILIO_ACCOUNT_SID?: string;
  TWILIO_AUTH_TOKEN?: string;
  TWILIO_FROM?: string;
  TWILIO_MESSAGING_SERVICE_SID?: string;
  DRY_RUN?: string;
}

/** `reason` is a short, number-free explanation safe to show in the app. */
export type SendResult = { ok: true } | { ok: false; retryable: boolean; status?: number; reason?: string };

export type Fetch = (input: string, init: RequestInit) => Promise<Response>;

/** Masks a number for logs so no full phone number is ever written anywhere. */
export function maskPhone(phone: string): string {
  return phone.length <= 4 ? '****' : `${phone.slice(0, 2)}******${phone.slice(-2)}`;
}

export async function sendText(config: TwilioConfig, to: string, body: string, fetchImpl: Fetch = fetch): Promise<SendResult> {
  const sid = config.TWILIO_ACCOUNT_SID;
  const token = config.TWILIO_AUTH_TOKEN;
  if (!sid || !token || (!config.TWILIO_FROM && !config.TWILIO_MESSAGING_SERVICE_SID)) {
    console.error('No text service configured: set TEXTBELT_KEY, or the Twilio secrets');
    return { ok: false, retryable: false, reason: 'The server has no text service set up.' };
  }

  const form = new URLSearchParams({ To: to, Body: body });
  if (config.TWILIO_MESSAGING_SERVICE_SID) form.set('MessagingServiceSid', config.TWILIO_MESSAGING_SERVICE_SID);
  else form.set('From', config.TWILIO_FROM!);

  try {
    const response = await fetchImpl(`https://api.twilio.com/2010-04-01/Accounts/${encodeURIComponent(sid)}/Messages.json`, {
      method: 'POST',
      headers: {
        Authorization: `Basic ${btoa(`${sid}:${token}`)}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: form.toString(),
    });
    if (response.ok) return { ok: true };
    // 429 and 5xx are worth retrying; 4xx (bad number, opted out) are not.
    const retryable = response.status === 429 || response.status >= 500;
    console.error(`Twilio refused text to ${maskPhone(to)}: HTTP ${response.status}`);
    return { ok: false, retryable, status: response.status };
  } catch (error) {
    console.error(`Could not reach Twilio for ${maskPhone(to)}: ${(error as Error).message}`);
    return { ok: false, retryable: true };
  }
}

// Chooses how texts are sent. Textbelt when TEXTBELT_KEY is set (simplest:
// no phone number to buy, no carrier registration on our side), otherwise
// Twilio. DRY_RUN logs instead of sending.

import { maskPhone, sendText as sendTwilio, type Fetch, type SendResult, type TwilioConfig } from './twilio.ts';

export interface SmsConfig extends TwilioConfig {
  TEXTBELT_KEY?: string;
}

export async function sendSms(config: SmsConfig, to: string, body: string, fetchImpl: Fetch = fetch): Promise<SendResult> {
  if (config.DRY_RUN === 'true') {
    console.log(`[dry run] text to ${maskPhone(to)}: ${body.length} chars`);
    return { ok: true };
  }
  if (config.TEXTBELT_KEY) return sendTextbelt(config.TEXTBELT_KEY, to, body, fetchImpl);
  return sendTwilio(config, to, body, fetchImpl);
}

/** https://textbelt.com: one POST with phone, message and key. */
export async function sendTextbelt(key: string, to: string, body: string, fetchImpl: Fetch = fetch): Promise<SendResult> {
  try {
    const response = await fetchImpl('https://textbelt.com/text', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ phone: to, message: body, key }).toString(),
    });
    if (response.status === 429 || response.status >= 500) {
      console.error(`Textbelt unavailable for ${maskPhone(to)}: HTTP ${response.status}`);
      return { ok: false, retryable: true, status: response.status };
    }
    const json = (await response.json().catch(() => ({}))) as { success?: boolean; error?: string; quotaRemaining?: number };
    if (json.success) {
      if (typeof json.quotaRemaining === 'number' && json.quotaRemaining < 20) {
        console.warn(`Textbelt credit is low: ${json.quotaRemaining} texts left`);
      }
      return { ok: true };
    }
    // Out of credit, bad number, blocked content: retrying won't help.
    console.error(`Textbelt refused text to ${maskPhone(to)}: ${json.error ?? `HTTP ${response.status}`}`);
    return { ok: false, retryable: false, status: response.status };
  } catch (error) {
    console.error(`Could not reach Textbelt for ${maskPhone(to)}: ${(error as Error).message}`);
    return { ok: false, retryable: true };
  }
}

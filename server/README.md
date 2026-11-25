# Spotter server

A Cloudflare Worker that sends Spotter's texts through Twilio and acts as the backup when the phone goes quiet. Each session is one Durable Object that holds the contacts and last location, runs the timers, and deletes everything when the session ends (or at most 12 hours after it starts, or 1 hour after its planned end).

## Endpoints

All `POST` with a JSON body. Every request needs `X-App-Key` when `APP_KEY` is set. Session routes also need `Authorization: Bearer <token>` from the start call.

| Route | Purpose |
| --- | --- |
| `/v1/sessions` | Start a session. Body: `firstName`, `contacts` (1 to 3 of `{name, phone}` in E.164), `timeZone`, optional `plannedDurationSec`, `heartbeatTimeoutSec`, `location`. Returns `{sessionId, token}`. |
| `/v1/sessions/:id/heartbeat` | Every 20 seconds. Optional `location`. |
| `/v1/sessions/:id/check-in` | A check-in started. `reason` (`lowOxygen` or `signalLost`), `deadline` (epoch ms). |
| `/v1/sessions/:id/check-in/clear` | The person tapped "I'm OK". |
| `/v1/sessions/:id/alert` | The countdown ran out. Idempotent. |
| `/v1/sessions/:id/safe` | "I'm safe now". Texts contacts if they were alerted, then ends the session. |
| `/v1/sessions/:id/low-battery` | Phone is about to die. Texts once. |
| `/v1/sessions/:id/end` | Ends the session and deletes its data. |
| `/v1/test` | Setup test text to each contact. Rate limited per number. |
| `/v1/welcome` | "You've been added" text to one contact. Rate limited per number. |

Location is `{lat, lon, accuracy, at}` with `at` in epoch milliseconds.

## Timers

| When | Text |
| --- | --- |
| No heartbeat for 2 minutes (and no alert yet) | "[Name]'s safety app lost contact. Please check on them." with last location |
| Heartbeat returns after that | "back in contact... please still check on them" |
| Check-in deadline + 20 seconds with no "I'm OK" or alert | The full alert |
| 5 minutes after an alert with no "I'm safe now" | Follow-up |

Failed texts are retried with backoff (up to 6 attempts). Each session can send at most 40 texts. Phone numbers never appear in logs; they're masked like `+1******01`.

## Deploy

```sh
npm install
npx wrangler login
npx wrangler deploy
npx wrangler secret put APP_KEY                     # any long random string; same value in Config/Secrets.xcconfig
npx wrangler secret put TWILIO_ACCOUNT_SID
npx wrangler secret put TWILIO_AUTH_TOKEN
npx wrangler secret put TWILIO_FROM                 # or TWILIO_MESSAGING_SERVICE_SID
```

Then set `DRY_RUN = "false"` in `wrangler.toml` and deploy again. While `DRY_RUN` is `"true"`, texts are only logged (`npx wrangler tail` to watch).

Durable Objects with SQLite storage work on the Workers free plan. If your account doesn't have the rate limiting binding, delete the `[[ratelimits]]` block; the code skips the limit when it's missing.

US carriers need the sending number registered (10DLC or toll-free verification) before texts go through reliably. Start that early; it takes weeks.

## Develop

```sh
npm test            # state machine, API, messages, Twilio client
npm run typecheck
npx wrangler dev    # local server on :8787 with real Durable Objects
```

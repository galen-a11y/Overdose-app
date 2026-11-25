# Spotter

An iPhone app that watches a Wellue Bluetooth fingertip oximeter while someone uses alone. If their oxygen stays low or the signal goes quiet and they don't respond to a loud check-in, it texts their emergency contacts their location. The full spec is in [docs/SPEC.md](docs/SPEC.md).

"Spotter" is a working name, chosen to be neutral on the home screen. Change `CFBundleDisplayName` in `App/Info.plist` to rename it.

## What's here

| Folder | What it is | Tested how |
| --- | --- | --- |
| `SafetyCore/` | Swift package with the logic that has to be right: the PC-60FW packet decoder, the alert engine, phone number handling, the offline outbox, and scripted fake-sensor scenarios. Foundation only. | 35 unit tests (`swift test`), run on Linux and macOS |
| `App/` | The SwiftUI iPhone app: Bluetooth, alarm, notifications, location, onboarding, session screens, settings. | Built by CI on macOS; needs a real phone for the rest (see below) |
| `server/` | Cloudflare Worker that sends texts (Textbelt or Twilio) and runs the heartbeat backup. One Durable Object per session. | 33 tests (`npm test`), typecheck, and a smoke test in `wrangler dev` |
| `project.yml` | XcodeGen project definition. The `.xcodeproj` is generated, not committed. | |

## How it works

```
Oximeter --BLE--> PC60FWSensor --> SensorHub --> SessionManager --> AlertEngine (SafetyCore)
                                                    |    |    |
                                                 alarm  local  server (heartbeat every 20 s,
                                                 siren  notifs  check-in, alert, safe, end)
                                                                  |
                                                       Durable Object timers --> Twilio texts
```

Three layers, so that one failing doesn't mean silence:

1. **The app's alarm.** A siren through the `.playback` audio category (not muted by the silent switch) plus vibration, during the 30-second check-in and after an alert.
2. **Local notifications.** A burst of time-sensitive (later critical) notifications through each countdown, and a "Spotter stopped watching" notification that fires if the app stops refreshing it, for example after being swiped away.
3. **The server.** If the app reports a check-in and then goes quiet, the server sends the alert itself 20 seconds after the deadline. It sends a follow-up 5 minutes after an alert unless the person taps "I'm safe now". If heartbeats stop for 2 minutes it sends a softer "lost contact" text.

Alert rules (all adjustable in Settings, all placeholders until a clinician reviews them): oxygen below 90% for 20 seconds, or no valid reading for 15 seconds, starts a check-in. Readings with a perfusion index below 0.3% are skipped as weak, and a long run of them counts as signal lost. Probe-off frames from the device are treated as "no data", never as "all clear".

### Choices I made that the spec left open

- **Staying alive with the screen locked.** The app runs continuous location updates during a session (with the blue indicator showing). That keeps the location fresh for alerts and keeps the app's timers running in the background. It also arms the audio session silently at session start, because iOS often refuses to *start* audio from the background. Both are worth explaining in App Review notes.
- **Who owns the countdown.** Both the phone and the server do. The phone alerts at 30 seconds; the server alerts at 50 if it never heard "I'm OK" or "alert". The server de-duplicates.
- **No lock-screen "I'm OK" button.** Tapping a notification opens the app, where the full-screen check-in is. This avoids an accidental tap from the lock screen.
- **"I'm OK" restarts the windows.** If oxygen is still low, a new check-in starts 20 seconds later. That partly answers the "tapped OK while impaired" open question; a deliberate second check-in a few minutes later is still worth discussing.
- **Timed sessions never end during a check-in or after an alert.** They end at the next normal moment.
- **"I'm safe now"** texts contacts only if they were told something was wrong (alert, lost contact, or low battery), then ends the session.
- **Packet format.** Cross-checked against Viatom's own Android SDK on GitHub (`viatomEcho/LepuBle`), which confirmed the CRC-8/Maxim checksum, the little-endian pulse rate, the probe-off and searching status bits, and the battery frame. Still confirm on the real unit (build step 1).

## Getting started on a Mac

You need Xcode 16 or later, an Apple Developer account, and the oximeter.

```sh
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # then fill in team ID, bundle ID, server URL, app key
xcodegen generate
open Spotter.xcodeproj
```

Then pick your iPhone as the run destination and run. In the Apple Developer portal, enable the **Time Sensitive Notifications** capability for the App ID.

To run the core tests: `cd SafetyCore && swift test` (or the Spotter scheme's Test action in Xcode).

To try everything without the oximeter: Settings > Developer > Use fake oximeter, then pick a scenario (sudden drop, slow drift, finger out, weak signal, brief dip). Each one walks the real decoder and alert engine.

## Deploying the server

See [server/README.md](server/README.md). The short version: `cd server && npm install && npx wrangler deploy`, set the app key and Textbelt (or Twilio) secrets, then put the Worker URL in `Config/Secrets.xcconfig`. Until texting is set up, `DRY_RUN = "true"` in `wrangler.toml` logs texts instead of sending them.

## Status against the build plan

| Step | State |
| --- | --- |
| Start now: Apple Developer account, Critical Alerts request | Yours to do. When approved, uncomment the entitlement in `App/Spotter.entitlements`. |
| Start now: Twilio account, 10DLC or toll-free registration | Yours to do. The texts include "Reply STOP" in the welcome message for compliance. |
| 1. Bluetooth test | Built: Settings > Oximeter > Raw Bluetooth packets shows hex frames, decoded values, and checksum counts. Needs the real device. |
| 2. Live readings | Built: decoder tested; reconnects automatically. Needs the real device. |
| 3. Alert engine | Built and unit tested with fake readings (low oxygen, slow drift, finger out, weak signal, brief dip, timers). |
| 4. Alarm and check-in | Built. Needs testing on a phone that is locked and on silent. |
| 5. Background | Built (location + Bluetooth background modes, state restoration, session resume after relaunch). Needs the one-hour locked-screen test. |
| 6. Server and texts | Built and tested end to end in Node and in `wrangler dev`. Needs a Cloudflare account and Twilio. |
| 7. Setup and contacts | Built: onboarding, welcome texts, permissions, test text with per-contact confirmation. |
| 8. Real-world testing | Not started. Use TestFlight with false-alarm and dead-battery drills before anyone relies on it. |

### Things only a real phone can confirm

- The oximeter's model and packet format (step 1), and how often it sends readings.
- That the siren sounds with the phone locked and the silent switch on, including when the check-in starts while the app is in the background.
- That iOS keeps the app running for a full session with the screen locked, and relaunches it for Bluetooth after it is suspended.
- Battery drain over a few hours of continuous location plus Bluetooth.

## Open questions still open

From the spec: the clinician review of the thresholds and countdown, the impaired "I'm OK" problem, the final app name, who pays for Twilio and hosting, and whether this is distributed with a TEP-provided oximeter. The old ChatGPT-era Xcode project wasn't used.

Not legal advice: keep App Store, website and grant language away from claims that the app prevents overdose deaths (see the regulation section of the spec).

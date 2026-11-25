# Overdose Alert App: First Version Spec

Nov 24, 2026 · @Galen

## Overview

Version 1 is an iPhone app, written in Swift, that watches a Wellue Bluetooth fingertip oximeter while someone uses alone. If oxygen stays low or the signal goes quiet and they don't respond, it texts their emergency contacts with their location.

**Who it's for:** one person, on their own phone, who sets it up themselves and starts it before they use. There's no outreach worker or organization account in the loop.

**Goals for version 1**

- Reliable alert within about a minute of a sustained low reading or lost signal
- Few false alarms, through a loud check-in the person can cancel
- Works with the screen locked and the phone on silent
- Setup in under five minutes, no account required

**Not in version 1**

- Android
- Auto-calling 911
- Accounts, logins or a web dashboard
- History, charts or reports
- Support for other oximeter brands

## User flow

The person sets the app up once, then starts a session each time they use and ends it when they're safe.

1. **One-time setup**
   - Pair the oximeter (scan, tap it, confirm a live reading)
   - Add one to three emergency contacts by name and phone number; each contact gets a text saying they've been added and what an alert means
   - Allow notifications, critical alerts and location
   - Run a test alert that texts contacts a clearly labeled test message
2. **Start a session**
   - Tap Start; the app confirms the oximeter is connected and reading
   - Optional: pick a session length (for example 1, 2 or 4 hours) so it ends on its own
3. **Monitoring**
   - Large, simple screen: current oxygen, pulse, connection status, time running
   - Keeps working with the screen locked
4. **Check-in** (when something looks wrong)
   - Loud alarm plus vibration, full-screen "I'm OK" button, countdown
   - Tapping "I'm OK" stops the alarm and keeps monitoring
5. **Alert** (no response before the countdown ends)
   - Text to every contact with the person's first name, what triggered it, a map link and the time
   - The phone keeps alarming so anyone nearby can find the person
6. **End session**
   - Tap End (with a hold or confirm so it isn't hit by accident), or let the timer run out
   - If an alert went out, the app offers a one-tap "I'm safe now" text to contacts

## Hardware

Build around the Wellue Bluetooth fingertip oximeter, but confirm the exact model on its label first. Wellue sells several Bluetooth fingertip units, and they don't all speak the same Bluetooth language.

**Most likely model:** the Wellue (Viatom) PC-60FW family, sold as the Bluetooth OxySmart. It offers both spot-check and continuous modes ([Viatom](https://medicalexpo.com/prod/viatom-lepu/product-100940-1010080.html)).

**How it talks over Bluetooth (PC-60FW)**

- It uses the Nordic UART service, `6e400001-b5a3-f393-e0a9-e50e24dcca9e`, with readings on the notify characteristic `6e400003-b5a3-f393-e0a9-e50e24dcca9e` ([Home Assistant community](https://community.home-assistant.io/t/esphome-bluetooth-tracker-for-contec-pc-60fw-fingertip-oximeter/969609))
- Each packet starts with the sync bytes `0xAA 0x55`, then a type byte, then a length byte that includes the trailing checksum ([open-source decoder](https://git.koelner.dedyn.io/coelner/viatom_pc60fw))
- Readings include oxygen, pulse and perfusion index (signal strength)
- None of this is officially documented by Wellue. It comes from people who decoded the device, so the first build step is confirming it on the actual unit.

**Limits that shape the design**

- The device powers itself on and off: when the finger comes out, measuring stops ([Wellue](https://getwellue.com/pages/oxysmart-fingertip-pulse-oximeter)). The app has to treat that as signal loss, not as "all clear."
- A fingertip clip isn't built for hours of wear. It can slip off, pinch, or give bad readings with movement or cold hands.
- It runs on batteries, so a low battery means a dead sensor mid-session. The app should show battery level if the device reports it, and warn at session start.

**Worth considering for version 2:** a ring or strap-on sensor made for continuous wear, such as the [Wellue WearO2](https://getwellue.com/pages/wearo2-wearable-pulse-oximeter). Design the Bluetooth code behind a simple "sensor" interface so a second device can be added later without rewriting the app.

## Alert logic

Two things start a check-in: oxygen staying low, or the signal going quiet. Either way the person gets 30 seconds to tap "I'm OK" before contacts are texted.

&#91;embedded content: alert flow · 2 triggers, 1 check-in, 1 server backup\]

The server backup catches the case the phone can't: the app was closed or the phone died, so no check-in could happen.

| Rule | Starting setting | Notes |
| --- | --- | --- |
| Low oxygen | Below 90% for 20 seconds in a row | Adjustable in settings; short dips from movement are ignored |
| Signal lost | No valid reading for 15 seconds | Covers finger out, device off, Bluetooth drop |
| Weak signal | Readings with low signal strength are skipped | Too many skipped in a row counts as signal lost |
| Check-in countdown | 30 seconds | Alarm, vibration and flashing screen the whole time |
| Alert | Text to all contacts | First name, trigger, map link, time |
| Follow-up | Second text after 5 minutes if no one taps "I'm safe now" | Alarm keeps sounding until the session ends |
| Server backup | No heartbeat for about 2 minutes | Softer "lost contact" text |

These starting settings are placeholders until a clinician weighs in (see Open questions).

## Technical design

The phone does the watching and the alarming; a small server sends the texts and acts as a backup if the phone goes quiet.

**App (Swift, SwiftUI)**

- **Bluetooth:** Core Bluetooth with the `bluetooth-central` background mode and state restoration, so iOS can wake the app for Bluetooth events after it's suspended ([Apple](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html))
- **Big catch:** if the person swipes the app away, iOS won't relaunch it for Bluetooth ([Apple TN3115](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)). The app should say so plainly at session start, and the server backup below covers it.
- **Alarm sound:** while the app is running, play the alarm through the audio playback category, which isn't muted by the silent switch
- **Notifications:** Critical Alerts break through silent mode and Focus, but Apple must approve the entitlement first, and the person must also opt in ([Apple form](https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/)). Until it's approved, use time-sensitive notifications.
- **Location:** Core Location, grabbed at session start and refreshed during the session, so the alert always has a recent location
- **Storage:** contacts and settings stay on the phone (SwiftData or simple local storage)

**Server (small, serverless)**

- iPhone apps can't send a text without the person tapping Send, so the server sends alert texts through Twilio
- **Heartbeat backup:** during a session the app checks in every 15 to 30 seconds. If check-ins stop for about 2 minutes, the server texts contacts a softer message: "\[Name\]'s safety app lost contact. Please check on them."
- Endpoints: start session, heartbeat, send alert, end session, send test
- US carriers require text-sender registration (10DLC or toll-free verification) before texts go through reliably, so start that early
- Keep almost nothing: contact numbers arrive with the session and are deleted when it ends

## Edge cases

The rule for every case: when the app can't tell whether the person is OK, it checks in, and if nobody answers, it alerts.

| Situation | What the app does |
| --- | --- |
| Finger slips out, device powers off | Treated as signal loss: check-in, then alert |
| Bluetooth drops (out of range, interference) | Tries to reconnect for 15 seconds, then check-in |
| Bad readings from movement or cold hands | Ignores readings with weak signal strength; long stretches of only bad readings count as signal loss |
| Oximeter battery dies | Same as signal loss; low battery warning at session start |
| Phone battery low | Warns at session start below 20%; texts contacts if the phone is about to die mid-session |
| App swiped away or crashes | Server heartbeat backup texts contacts after about 2 minutes |
| Phone has no signal or internet | Alarm still sounds locally; texts queue and send when service returns; the session start screen shows a warning if there's no connection |
| Person forgets to end the session | Session timer ends it; a reminder fires 10 minutes before |
| Person taps "I'm OK" while impaired | Out of scope for version 1; noted as an open question |
| Contact's number is wrong | Test alert during setup confirms each contact got it |

## Privacy, safety and regulation

People using this are trusting it with something that could get them in legal trouble, so the app collects as little as possible and never pretends to be more than a backup.

**Privacy**

- No account, no name required beyond a first name for alert texts
- No session history kept on the server; nothing on the phone says what the person was doing
- App name and icon should be neutral (no "overdose" on the home screen)
- Alert texts say "\[Name\] may need help" and give the location, nothing about drugs

**Safety messaging in the app**

- It's a backup, not a guarantee: phones die, sensors slip, texts get delayed
- Point people to [Never Use Alone](https://crh.arizona.edu/never-use-alone-line), a free, peer-led line where a volunteer stays on the phone and sends help if the caller stops responding ([Filter](https://filtermag.org/?p=13164))
- Encourage contacts to keep naloxone and know how to use it

**Regulation** (not legal advice; worth a lawyer's review before public release)

- The FDA reissued its general wellness guidance on January 6, 2026 ([FDA](https://www.fda.gov/media/99809/download)). It now says some non-invasive wearable readings, including oxygen saturation, can count as general wellness outputs, but only without claims about diagnosing, treating or preventing disease ([McGuireWoods](https://www.mcguirewoods.com/client-resources/alerts/2026/1/signaling-more-flexibility-fda-says-more-wearable-devices-qualify-for-general-wellness-exception/)).
- "Prevents overdose deaths" is a prevention claim, so it likely falls outside that safe zone. How the app is described in the App Store, on TEP's site and in grant materials matters as much as the code.
- Apple also reviews health and safety apps closely; the Critical Alerts request is a good place to explain the purpose clearly.

## Build plan

Build in this order, and don't start the next step until the current one works on a real phone with the real oximeter. Hand each step to Claude Code with this spec in the project folder.

**Start now, in parallel (these take weeks of waiting):**

- [ ] Apple Developer account and Critical Alerts entitlement request
- [ ] Twilio account and text-sender registration

**Build steps**

1. **Bluetooth test:** a bare app that finds the oximeter, connects, and prints raw packets to the screen. Confirms the model and the packet format.
2. **Live readings:** decode oxygen, pulse and signal strength; show them on a simple screen; handle disconnects and reconnects.
3. **Alert engine:** the rules in Alert logic, built as plain Swift with unit tests that feed in fake readings (low oxygen, slow drift, finger out, bad signal).
4. **Alarm and check-in:** loud alarm, full-screen "I'm OK," countdown; test with the phone locked and on silent.
5. **Background:** keep monitoring with the screen locked for a full hour; test with the app in the background and after iOS suspends it.
6. **Server and texts:** start/heartbeat/alert/end endpoints, Twilio texts, heartbeat backup.
7. **Setup and contacts:** onboarding, contacts, permissions, test alert.
8. **Real-world testing:** TestFlight with a few trusted people, including false-alarm and dead-battery drills, before anyone relies on it.

**Tip for Claude Code:** let it run `xcodebuild` itself so it can read its own errors, and keep Bluetooth code behind a `PulseSensor` protocol with a fake sensor for testing without the device.

## Open questions

- [ ] Exact oximeter model on the label (PC-60FW or another Wellue unit)?
- [ ] Is 90% oxygen for 20 seconds the right trigger? Worth asking a clinician or harm reduction medical advisor.
- [ ] How long should the check-in countdown be: 30 seconds, or longer?
- [ ] How do we handle someone tapping "I'm OK" while too impaired to be OK (for example, a second check-in a few minutes later)?
- [ ] Should the old ChatGPT-era Xcode project be mined for anything before starting fresh?
- [ ] App name: something neutral for the home screen?
- [ ] Who pays for Twilio and hosting, and is this a TEP grant line item?
- [ ] Free to everyone, or distributed with a TEP-provided oximeter later?

## Sources

- [Viatom PC-60FW product page](https://medicalexpo.com/prod/viatom-lepu/product-100940-1010080.html)
- [PC-60FW Bluetooth decoder notes](https://git.koelner.dedyn.io/coelner/viatom_pc60fw)
- [Home Assistant PC-60FW configuration](https://community.home-assistant.io/t/esphome-bluetooth-tracker-for-contec-pc-60fw-fingertip-oximeter/969609)
- [Wellue OxySmart](https://getwellue.com/pages/oxysmart-fingertip-pulse-oximeter)
- [Apple: Core Bluetooth background processing](https://developer.apple.com/library/archive/documentation/NetworkingInternetWeb/Conceptual/CoreBluetooth_concepts/CoreBluetoothBackgroundProcessingForIOSApps/PerformingTasksWhileYourAppIsInTheBackground.html)
- [Apple TN3115: state restoration relaunch rules](https://developer.apple.com/documentation/technotes/tn3115-bluetooth-state-restoration-app-relaunch-rules)
- [Apple Critical Alerts entitlement request](https://developer.apple.com/contact/request/notifications-critical-alerts-entitlement/)
- [FDA general wellness town hall, 2026](https://www.fda.gov/media/99809/download)
- [McGuireWoods on the 2026 wellness guidance](https://www.mcguirewoods.com/client-resources/alerts/2026/1/signaling-more-flexibility-fda-says-more-wearable-devices-qualify-for-general-wellness-exception/)
- [Never Use Alone Line](https://crh.arizona.edu/never-use-alone-line)

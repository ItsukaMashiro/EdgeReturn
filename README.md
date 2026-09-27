# EdgeReturn

An iOS app (IPA) that adds **Android-style right-edge swipe-back** to your iPhone.
Swipe in from the **right edge** and the current app goes back — the same feel
as Android's edge navigation, using iOS's own native back gesture under the hood.

It runs as a **resident background service** so the gesture works across all apps,
not just this one.

## How it works

| Piece | Mechanism |
|-------|-----------|
| **System-wide touch detection** | Private IOKit HID API (`IOHIDEventSystemClient` + event dispatch) observes raw touch events from every app. If the private API is unavailable on a future iOS, it falls back to an in-app right-edge gesture. |
| **Back action** | Injects a synthetic **left-edge swipe** (iOS's native back gesture) via `IOHIDEventCreateDigitizerEvent` + `IOHIDEventSystemClientDispatchEvent`. Any app with back navigation pops. |
| **Android feel** | The gesture model mirrors Android's edge navigation: edge touch → light haptic tick, crossing the engage distance → firmer tick (like Android's drag indicator), release past the complete distance **or a fast flick** → the back fires, and the injected swipe is **paced to your actual swipe time** so the native animation follows the pace of your finger. Releasing short of the thresholds cancels, exactly like Android's cancelable drag. |
| **Long-press edge** | Optional (toggle in the UI): hold in the edge zone and a synthetic **bottom-edge swipe** is injected (home / app switcher), like Android's long-press-edge. |
| **Background persistence** | Continuous `CLLocationManager` updates + a silent looping `AVAudioSession` + a watchdog that re-asserts both, plus an optional keep-screen-awake toggle. |
| **UI** | SwiftUI: enable toggles, edge-width / engage / complete-distance sliders (all persisted), live edge indicator on the right edge, service status, test buttons, and an event log. |

> The private HID APIs are the "magic" part. If a future iOS release changes
> them, only `TouchService.swift` + `HIDPrivateAPI.h` need updating.

## Project layout

```
project.yml                       # XcodeGen spec (generates the .xcodeproj in CI)
Sources/
  EdgeReturnApp.swift            # @main + AppDelegate wiring
  ContentView.swift              # SwiftUI UI
  TouchService.swift             # gesture model + HID observer + injector (private API)
  BackgroundKeeper.swift         # location + audio + watchdog keep-alive
Support/
  HIDPrivateAPI.h                # bridging header: private IOKit declarations
  Info.plist                     # background modes, location usage
  EdgeReturn.entitlements
.github/workflows/build-ipa.yml  # macOS CI: XcodeGen → archive → export IPA
ExportOptions.plist              # template (overwritten by CI with real teamID)
```

## Building the IPA (GitHub Actions)

The build runs on a **macOS** runner (there's no Xcode on Windows).

### 1. Secrets you must add to the repo

| Secret | What it is |
|--------|-----------|
| `CERTIFICATE_P12` | Your iOS **development .p12** certificate, **base64-encoded** (`base64 -w0 cert.p12`). The current one opens with an **empty password**. |
| `P12_PASSWORD` | The password you exported the .p12 with (empty string for the current one). |
| `PROVISIONING_PROFILE` | A **development .mobileprovision**, **base64-encoded**, that includes your device's UDID and the bundle id `com.itsukamashiro.edgereturn`. |

The team id and profile UUID are read **from the provisioning profile**, so you
don't need a separate `TEAM_ID` secret.

> The profile **must** contain your device UDID (for `development`/`ad-hoc`) and
> match the bundle identifier `com.itsukamashiro.edgereturn`. The current
> profile is tied to one device UDID and **expires 2026-10-03** — re-issue it
> (e.g. via the provisioner that created it) before then.

### 2. Trigger the build

- **Automatic:** pushed to `main`.
- **Manual:** Actions → *Build EdgeReturn IPA* → *Run workflow* (pick the export method).

### 3. Download the IPA

The workflow uploads `EdgeReturn.ipa` as an artifact. Download it and sideload
with [Sideloadly](https://sideloadly.io), [AltStore](https://altstore.io), or
Apple Configurator.

## First run on the device

1. Install the IPA.
2. Open **EdgeReturn** → grant **Always** when asked for location (this keeps
   the service alive).
3. Toggle **Right-edge swipe → back** on.
4. Open any app with a back button (Safari, a settings screen, a chat) and
   swipe in from the **right edge** — it should go back.
5. Use **Test back** / **Test home** to verify the injection works.

## Tuning

- **Edge width** — how close to the right edge a touch must start (default 28 pt).
- **Engage distance** — how far left before the gesture "engages" (haptic tick, default 35 pt).
- **Complete distance** — how far left a release must travel to complete (default 55 pt).
- A fast **flick** (≥ 500 pt/s) completes the back even short of the distance.

Settings persist across launches.

## Notes & caveats

- **Private APIs:** the touch observer/injector uses non-public IOKit symbols.
  This is fine for sideloaded (non-App-Store) apps, but would be rejected by
  App Store review.
- **Battery:** the keep-alive (location + audio) uses a little extra power. That
  is the trade-off for a resident service on iOS.
- **Back coverage:** the injected left-edge swipe triggers the *native* back
  gesture, so it works wherever iOS back navigation works (nav stacks, etc.).
  Apps with a custom back button that isn't wired to the system gesture may
  need the on-screen back button.
- **Edge indicator:** the live indicator bar on the right edge is visible while
  EdgeReturn itself is in the foreground (iOS doesn't allow drawing over other
  apps without jailbreak); the haptic ticks still fire.

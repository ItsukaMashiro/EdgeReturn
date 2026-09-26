# EdgeReturn

An iOS app (IPA) that adds **Android-style right-edge swipe-back** to your iPhone.
Swipe in from the **right edge** and the current app goes back — the same feel
as Android's edge navigation, using iOS's own native back gesture under the hood.

It runs as a **resident background service** so the gesture works across all apps,
not just this one.

## How it works

| Piece | Mechanism |
|-------|-----------|
| **System-wide touch detection** | Private IOKit HID API (`IOHIDEventSystemClient` + event dispatch) observes raw touch events from every app. |
| **Back action** | Injects a synthetic **left-edge swipe** (iOS's native back gesture) via `IOHIDEventCreateDigitizerEvent` + `IOHIDEventSystemClientDispatchEvent`. Any app with back navigation pops. |
| **Background persistence** | Continuous `CLLocationManager` updates + a silent looping `AVAudioSession` — the two most reliable keep-alives, so iOS won't terminate the process. |
| **UI** | SwiftUI: enable toggle, edge-width / swipe-distance sliders, live touch-event debug view, and a "Test back" button. |

> The private HID APIs are the "magic" part. If a future iOS release changes them,
> only `TouchService.swift` + `HIDPrivateAPI.h` need updating.

## Project layout

```
project.yml                       # XcodeGen spec (generates the .xcodeproj in CI)
Sources/
  EdgeReturnApp.swift            # @main + AppDelegate wiring
  ContentView.swift              # SwiftUI UI
  TouchService.swift             # HID observer + injector (private API)
  BackgroundKeeper.swift         # location + audio keep-alive
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
| `CERTIFICATE_P12` | Your iOS **distribution/development .p12** certificate, **base64-encoded** (`base64 -w0 cert.p12`). |
| `P12_PASSWORD` | The password you exported the .p12 with. |
| `PROVISIONING_PROFILE` | A **development or ad-hoc .mobileprovision**, **base64-encoded**, that includes your device's UDID and the bundle id `com.itsukamashiro.edgereturn`. |

The team id and profile UUID are read **from the provisioning profile**, so you don't
need a separate `TEAM_ID` secret.

> The profile **must** contain your device UDID (for `development`/`ad-hoc`) and
> match the bundle identifier `com.itsukamashiro.edgereturn`.

### 2. Trigger the build

- **Manual:** Actions → *Build EdgeReturn IPA* → *Run workflow* (pick the export method).
- **Automatic:** pushed to `main`.

### 3. Download the IPA

The workflow uploads `EdgeReturn.ipa` as an artifact. Download it and sideload with
[Sideloadly](https://sideloadly.io), [AltStore](https://altstore.io), or Apple Configurator.

## First run on the device

1. Install the IPA.
2. Open **EdgeReturn** → grant **Always** when asked for location (this keeps the service alive).
3. Toggle **Enable back swipe** on.
4. Open any app with a back button (Safari, a settings screen, a chat) and swipe in
   from the **right edge** — it should go back.
5. Use **Test back** to verify the injection works.

## Tuning

- **Edge width** — how close to the right edge a touch must start (default 28 pt).
- **Swipe distance** — how far left you must travel to trigger (default 55 pt).

If the gesture is too easy/hard to trigger, adjust these in the UI (they persist per
session; the `TouchService` defaults are in `TouchService.swift`).

## Notes & caveats

- **Private APIs:** the touch observer/injector uses non-public IOKit symbols. This is
  fine for sideloaded (non-App-Store) apps, but would be rejected by App Store review.
- **Battery:** the keep-alive (location + audio) uses a little extra power. That's the
  trade-off for a resident service on iOS.
- **Back coverage:** the injected left-edge swipe triggers the *native* back gesture, so
  it works wherever iOS back navigation works (nav stacks, etc.). Apps with a custom
  back button that isn't wired to the system gesture may need the on-screen back button.

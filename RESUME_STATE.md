# RESUME STATE (updated 2026-09-27 ~13:30 UTC)

## Current blocker: provisioning profile "Xcode managed" rejection
- xcodebuild rejects Manual signing when the profile Name matches Xcode's auto
  pattern ("iOS Team Provisioning Profile: ...").
- Local re-encoding (surgical Name patch OR full CMS re-wrap) BOTH fail:
  Security.framework verifies Apple's CMS signature -> "missing UUID" load error.
  => Local rename is a DEAD END. Profile must be renamed server-side by Apple.

## Just pushed (commit a8d1098): Automatic signing attempt
- `.github/workflows/build-ipa.yml` now uses CODE_SIGN_STYLE=Automatic
  (xcodebuild downloads+manages the profile itself; the Name pattern only
  conflicts with Manual signing). Wrapped in a 600s watchdog + an Apple
  reachability probe step.
- MONITOR: `gh run list --repo ItsukaMashiro/EdgeReturn --limit 1`
  - If it SUCCEEDS: download the IPA artifact
      `gh run download <id> --repo ItsukaMashiro/EdgeReturn -n EdgeReturn.ipa -D E:\iosReturn`
  - If it FAILS/times out (Apple unreachable on runner): fall back to
    server-side rename (below).

## Fallback: server-side rename via Apple (needs user help)
- The provisioner (E:\codexWorkspace\ios-signing-tools\wda-provisioner) uses
  isideload session login (Apple ID + 2FA). Env WDA_APPLE_ID / WDA_APPLE_PASSWORD
  are set (user scope). It can DOWNLOAD a profile but not rename/create one
  with a custom name.
- Cleanest: USER renames the profile in the App Store Connect / developer web
  UI ("iOS Team Provisioning Profile: com.itsukamashiro.edgereturn" ->
  "EdgeReturn-Dev"), downloads the .mobileprovision, and hands it over. Then:
  `gh secret set PROVISIONING_PROFILE --body "<base64 of renamed profile>"`
  and revert the workflow to Manual signing (CODE_SIGN_STYLE=Manual +
  PROVISIONING_PROFILE=$PROFILE_UUID). UUID is unchanged by a rename.
- ASC API key (EC .p8) does NOT appear to exist on this machine. The 1218-byte
  DER key in the Windows Credential Manager (service codex-wda-provisioner) is
  the RSA P12 dev-cert private key, NOT an ASC API key. Saved at
  C:\Users\17941\.dsh\secrets\asc-api-key.der (mislabeled; it's the P12 key).
- Team W7N8KKFFF2 (Individual). Profile UUID b1886eba-1d74-4a47-a69d-9c35e59b5bfe
  (expires 2026-10-03 — re-issue soon). Bundle com.itsukamashiro.edgereturn.
  Device UDID 00008150-001C3C123C78401C.

## Device-side (deferred; iPhone disconnected by user)
- When iPhone reconnects: restart tunneld + usbmux forward (8100), launch WDA,
  install the built IPA, launch com.itsukamashiro.edgereturn, read the app's
  on-screen event log via WDA screenshots (symbol resolution, observer status,
  raw-event encodings, which constant set A/B triggers system back/home,
  system-wide observation, background persistence via developer dvt proclist).
- Iterate TouchService.swift constants based on observed results.

## Key files
- Sources/TouchService.swift (v2 self-calibrating), ContentView.swift (injectionSet
  picker + test buttons), BackgroundKeeper.swift, Support/HIDPrivateAPI.h,
  project.yml, Support/Info.plist (UIBackgroundModes location+audio).
- tools/rename_profile.py (full CMS re-wrap; DEAD END for xcodebuild, keep for ref).
- signing/runner.mobileprovision (original Apple profile).

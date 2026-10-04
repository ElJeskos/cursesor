# Protected click routing: 1.2.17 build 20

## Symptom and diagnosis

See [the physical Little Nightmares III trace](little-nightmares-click-trace-1.2.16.md). Five complete clicks were submitted to the correct game PID at Y=37, but did not produce game actions.

A receiving-side CrossOver test isolated the difference. A painted, fullscreen Win32 probe registers mouse Raw Input and logs both WM_LBUTTONDOWN/UP and RAW button flags. Without SetCapture, PID-targeted Quartz events were ignored; with SetCapture they arrived. Normal routing delivered events without requiring SetCapture. This reproduces a concrete Wine routing failure, not proof of Little Nightmares III's internal window state.

A temporary app cloned from the installed helper and signed with the same designated requirement reported `post=1 listen=1 ax=1`. No TCC permissions were requested or changed. Unrelated unsigned executables' earlier failed permission checks did not apply to this signed probe.

## Fix

`forward_capture_button_to_game` now receives the callback's `CGEventTapProxy`. For the still-frontmost game it calls `CGEventTapPostEvent(proxy, copy)` rather than `CGEventPostToPid`.

The unsafe original is still discarded. The tagged copy retains X and uses fence+1 for Y. Down/up pairing and safe-anchor tracking remain. Original motion and drag events are unchanged; no cursor warp, reassociation or camera algorithm change was added.

Posting via `CGEventPost(kCGSessionEventTap, ...)` was rejected: although it delivered input, it displaced the physical cursor in the probe. Tap-proxy posting delivered input without this displacement.

When a release must target a game that has lost focus, or capture cleanup runs outside a callback, the existing PID route remains best-effort. It must not send a synthetic release to an unrelated foreground app. Receipt of these background/cleanup releases is not guaranteed by this change or its mock tests.

## Validation

- `SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk ./scripts/test_capture_button_delivery.sh`: new downstream-route assertions failed with PID-only implementation, then passed with the fix. Existing left/right/middle, paired-release, focus change, recursion, cleanup and unchanged serialized motion checks pass.
- `./scripts/build.sh`: universal arm64/x86_64, macOS 11 compatibility, defaults, provider detection, edge/watchdog policies, callback and capture-model tests all pass.
- Temporary receiving-side harness: `/tmp/gcf-cross-receive/run.py`, native driver `routes.m`, Win32 receiver `receiver.c`; logs `driver.log` and `received.log`. These are diagnostic artifacts, not an unattended supported project test suite. The harness was run with no real game active; it temporarily unloads the helper and restores its permanent LaunchAgent afterward. Its own Wine window exits after 30 seconds; shared Wine services are not terminated.
- Final receiving-side run: fixed production callback (phase 0) received exactly one WM down/up at `(320,37)` and RAW flags 1/2. PID control (phase 2) received none. Tap-copy comparison (phase 4) and ordinary Y=200 control (phase 5) each received one full click. Phase markers are written to a file and read by the Windows receiver, avoiding cross-clock timestamp inference.
- Physical cursor samples after both fixed-callback transitions remained `(1217,914)`. Separate explicit warps in the diagnostic harness reset the baseline between experimental routes; no warp is present in the production button path.
- `git diff --check` passes. Historical GameHub motion E2E scripts were not run and are not represented as this CrossOver test.

## Deployment

Installed on 2026-10-04 using `GCF_RUN_WINE_E2E=false ./scripts/build_install.sh` with the SDK above. `verify_companion.sh` confirms signed 1.2.17, enabled LaunchAgent, exactly one helper and working duplicate-launch guard.

App: `~/Applications/Game Cursor Fence.app`.
Backup of 1.2.16: `~/Library/Application Support/codex-game-cursor-fence/app-backups/Game Cursor Fence-20261004T181933Z-26574.app`.

No branch, commit, push or public release was created. Existing unrelated `.gitignore` changes were left untouched.

Still required: physical gameplay validation in Little Nightmares III, including top click action, no system arrow and unchanged camera feel. Receiving-side probe success does not substitute for that acceptance check.

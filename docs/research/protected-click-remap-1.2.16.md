# Protected click delivery: local 1.2.16 build 19

Date: 2026-10-03. Implements the user's explicit request to preserve system-side protection of the top strip while making the game receive a click just outside that strip. This supersedes the button-delivery policy diagnosed in [the 1.2.15 report](top-strip-click-delivery-diagnosis.md), not the accepted camera algorithm.

## Behavior

- The unsafe original down/up is still deleted from macOS global routing.
- A copy of the button event is posted with `CGEventPostToPid` to the verified foreground game. Its X is unchanged; Y is `top_fence_y() + 1.0` (normally `37`, beyond the protected `36.5` boundary).
- The copy preserves button identity, click count, modifiers, pressure, event number and the original button event type. Only the copy's location and recursion tag are changed.
- A redirected press stores its recipient PID and safe anchor. Release uses the same PID/anchor even after leaving the strip or losing focus, preventing split or stuck clicks.
- Capture disable/exit or tap disable balances an outstanding press. The later physical up is not delivered to the same game a second time. Fresh down starts a new click.
- Outside-strip and inactive clicks retain their original route. A stale foreground sample cannot swallow a different application's buttons.
- No live cursor warp, motion replay, delta rewrite or cursor reassociation was added to the button-delivery path. Existing activation parking, hiding and visibility-watchdog behavior remain. All regular motion/drag events keep their complete serialized event data.
- Activation-park suppression is now explicitly restricted to motion so it cannot discard a real button event carrying a large delta.

Implementation: [src/game-cursor-fence.c](../../src/game-cursor-fence.c). Original protected-area predicate remains in [src/capture_edge_policy.c](../../src/capture_edge_policy.c).

## Validation

New test: [tests/capture_button_delivery_test.c](../../tests/capture_button_delivery_test.c), run via:

```sh
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.5.sdk \
  ./scripts/test_capture_button_delivery.sh
```

It exercises the production Quartz callback on actual in-memory CGEvents. Only OS posting, cursor-control and foreground-PID boundaries are substituted. It never injects global input or stops the user's helper/game.

Red before green: the original implementation failed with `game must receive exactly one down and one up`; successive tests caught releases leaving the strip, cleanup balancing, duplicate post-cleanup release, stale focus and button suppression by the activation-park filter. All now pass.

Coverage includes left/right/middle buttons at Y `0`, `33`, `36`, `36.5`; default safe Y `37`; paired release outside the strip; focus loss; cleanup; copy re-entry; double-click metadata; ordinary/inactive clicks; all four motion/drag types. Motion before/after `CGEventCreateData` snapshots are equal and no motion is PID-posted.

`./scripts/build.sh` passed the universal macOS-11 compatibility check, default configuration, provider detection, edge policy, watchdog policy, button-delivery regression and capture-model checks. Changed shell scripts passed `bash -n` and ShellCheck; `git diff --check` passed.

The obsolete `test_top_click_no_teleport.sh` live test expected y=36 coordinate rewrites and restarted the user's helper. It now transparently delegates to the deterministic callback regression. The default installer uses the current watchdog policy test instead of the legacy live watchdog probe, which also expected removed coordinate rewrites. Legacy Wine/HID scripts remain manual historical probes and are not evidence that gameplay was validated.

A background AppKit native-PID delivery probe was attempted under `/tmp/gcf-native-button-delivery.uEgQ8G/`. Its standalone process had `CGPreflightPostEventAccess=false`, `CGPreflightListenEventAccess=false`, `AXIsProcessTrusted=false`; a signed temporary bundle also lacked these permissions and explicitly skipped with code 77. No TCC permissions were requested or changed. Consequently, native process delivery/visual behavior and the actual Wine game have **not** been validated by this probe. Early unprivileged attempts observed no received events; physical mouse movement while sampling cannot be attributed to the helper. This is a validation limitation, not a passing native E2E test.

## Prepared artifacts and deployment status

- Signed staged application: `dist/Game Cursor Fence-1.2.16.app`.
- Staged executable SHA-256: `8e9599101cce1ab69b0a92fc04629ba84d0da47ff41347d84109667039b8126f`.
- Installer: `dist/Game-Cursor-Fence-1.2.16-macOS-universal.dmg` and adjacent `.sha256`.
- Both architectures are present (`arm64`, `x86_64`), minimum macOS 11. The local certificate is `GameHub Cursor Helper Local Code Signing`, as before; no notarization or public GitHub release was performed.
- `package_portable.sh` ran with `GCF_SKIP_BUILD_INSTALL=true` and the staged app. DMG checksum, signatures, universal binaries, icon, embedded backend ShellCheck and package structure checks all passed. The production app was not replaced.

Initial deployment was postponed while Company of Heroes 2 (`RelicCoH2.exe`, PID 6146) and the CrossOver Steam wrapper (PID 253) were running. The user subsequently closed them, and `--check-running` returned `match=false`.

### Installation completed

`GCF_RUN_WINE_E2E=false ./scripts/build_install.sh` with the explicit SDK above installed **1.2.16 build 19** at `/Users/sviridov/Applications/Game Cursor Fence.app` on 2026-10-03. All build and installer checks passed. Installed executable SHA-256: `2c2a5112dfa8404dcedf8e00ff86f466c8598a6e75919733275c4a8aeba7b693`; its CodeDirectory hash is `bc9a079a8482e10477a4e978c446b758b53d3e92`, identical to the staged app. Whole-executable hashes differ after signing while the code hash is unchanged.

The signed 1.2.15 backup is `/Users/sviridov/Library/Application Support/codex-game-cursor-fence/app-backups/Game Cursor Fence-20261003T123513Z-49488.app`.

LaunchAgent `local.game-cursor-fence` is running with exactly one helper process (PID 49819 at verification). The runtime log reports `tap=capture-filter`; read-only `CGGetEventTapList` confirms its HID filter with button events in the mask. The tap is disabled while no game is active, as expected. No permission prompts or TCC changes were required during installation. Permission to post native synthetic events was not independently queried inside the installed process.

Remaining validation: user gameplay check of top-strip clicks and smooth camera motion. The Wine E2E probes were explicitly not run; a passing callback regression and successful event-tap startup are not a promise that every Wine/game input backend accepts PID-targeted copies.

Work stayed on `main`; no commit, branch, push, release or change to the pre-existing `.gitignore` edit was made.

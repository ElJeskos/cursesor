# Game Cursor Fence

Game Cursor Fence is a small background app for macOS that improves cursor behavior in Windows games running through GameHub or CrossOver.

## Download for macOS

Download the latest universal macOS installer from the [GitHub Releases page](https://github.com/ElJeskos/cursesor/releases/latest).

Choose `Game-Cursor-Fence-1.2.17-macOS-universal.dmg` under **Assets**.
The same download supports Apple silicon and Intel Macs running macOS 11 or later.

Version `1.2.17` (build `20`) delivers top-strip clicks at safe coordinates through normal event routing, preserving the existing camera behavior.

[Инструкция по установке на другой Mac](docs/INSTALL-RU.md).

## What it does

Some GameHub and CrossOver games can unexpectedly expose the macOS system cursor when a click lands in the strip at the top of the game window.
Game Cursor Fence keeps the system cursor hidden for those top-strip clicks and preserves smooth in-game camera movement when the physical mouse reaches the upper screen boundary.

The helper activates only while a detected GameHub or CrossOver game is frontmost.
Normal macOS cursor behavior returns as soon as focus leaves the game.

## Install

1. Download the DMG from [Releases](https://github.com/ElJeskos/cursesor/releases/latest).
2. Open the DMG.
3. Control-click `Install Game Cursor Fence.app`, choose **Open**, and confirm the launch.
4. Click **Install** in the installer window.
5. When prompted, enable Game Cursor Fence in both **Privacy & Security → Accessibility** and **Privacy & Security → Input Monitoring**.
6. Return to the installer and click **Check Again**.

The installer places the app at `~/Applications/Game Cursor Fence.app` and starts it automatically through a per-user LaunchAgent.
No administrator password is required.

The downloadable build is locally signed but is not notarized with an Apple Developer ID. macOS may require **Privacy & Security → Open Anyway** after a blocked launch; some versions also support Control-click **Open**. Only approve a download you trust. Do not disable Gatekeeper globally. Permissions must be granted separately on each Mac; no signing certificate or developer tools need to be transferred.

## How the fix works

When capture starts, the helper hides the system cursor and detaches physical mouse movement from the WindowServer cursor position.
It parks the hidden cursor once at a safe interior point and suppresses only the synthetic event created by that activation-time park.

Normal gameplay motion then passes to Wine unchanged.
The original event type, location, horizontal delta, and vertical delta are preserved without a PID-targeted duplicate, diagonal injection, event-type conversion, coordinate rewrite, or live boundary warp.

Original mouse-button events in the protected top strip are suppressed so macOS cannot handle the unsafe click. Only a button copy is posted downstream of the current event tap with `CGEventTapPostEvent`, keeping X and placing Y one point below the configured fence (`37` by default, outside the protected `36.5`-point boundary). This preserves WindowServer routing: PID-only copies can be ignored by Wine windows without mouse capture. The foreground game is checked before posting. Down/up use the same safe anchor, including release outside the strip. After focus loss, or during capture shutdown, releases remain best-effort PID-targeted events so unrelated applications never receive synthetic releases. Routed copies are tagged against duplicate handling. CrossOver receiving-side tests confirm WM/Raw Input delivery and no pointer displacement; Little Nightmares III gameplay acceptance is still required.

This button-only delivery does not warp or reassociate the physical cursor. Normal motion and drag events continue through unchanged; activation parking and the visibility watchdog retain the accepted camera behavior.
A latched visibility watchdog restores hidden detached capture without repeatedly reassociating the pointer during continuous input.

The concise implementation record is available in [Debag.md](Debag.md).

## Build from source

The project builds a universal `arm64` and `x86_64` binary with the system Clang toolchain.

```bash
./scripts/build.sh
```

To install the freshly built app for the current user, run:

```bash
./scripts/build_install.sh
```

The build requires macOS 11 or later, Xcode Command Line Tools, Accessibility permission, and Input Monitoring permission.
Set `GCF_SIGNING_IDENTITY` when using a specific local code-signing certificate.

The installer refuses to replace a running helper while a matching game is active.
Close the game before using the build-and-install pipeline.

## Verify

The source-level and binary checks can be run without installing the app:

```bash
./scripts/test_capture_edge_policy.sh
./scripts/test_capture_watchdog_policy.sh
./scripts/test_capture_button_delivery.sh
./scripts/test_binary_compatibility.sh ./bin/game-cursor-fence
./scripts/test_companion_defaults.sh ./bin/game-cursor-fence
./scripts/test_provider_detection.sh ./bin/game-cursor-fence
./scripts/test_capture_model.sh ./bin/game-cursor-fence
```

`test_capture_button_delivery.sh` exercises the production Quartz callback with OS output boundaries substituted; it never posts input or interrupts a running game. It checks exact-once button delivery, safe coordinates, paired releases, metadata, cleanup, and unchanged serialized motion/drag fields. This is not a substitute for testing the update inside the actual game.

Historical macOS HID and Wine Raw Input probes are also retained for manual end-to-end investigations; some still assume older coordinate-rewriting implementations.

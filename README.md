# Game Cursor Fence

Game Cursor Fence is a small background app for macOS that improves cursor behavior in Windows games running through GameHub or CrossOver.

## Download for macOS

Download the latest universal macOS installer from the [GitHub Releases page](https://github.com/ElJeskos/cursesor/releases/latest).

Choose `Game-Cursor-Fence-1.2.15-macOS-universal.dmg` under **Assets**.
The same download supports Apple silicon and Intel Macs running macOS 11 or later.

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

The downloadable build is locally signed but is not notarized with an Apple Developer ID, so macOS may require the Control-click **Open** step on first launch.

## How the fix works

When capture starts, the helper hides the system cursor and detaches physical mouse movement from the WindowServer cursor position.
It parks the hidden cursor once at a safe interior point and suppresses only the synthetic event created by that activation-time park.

Normal gameplay motion then passes to Wine unchanged.
The original event type, location, horizontal delta, and vertical delta are preserved without a PID-targeted duplicate, diagonal injection, event-type conversion, coordinate rewrite, or live boundary warp.

Mouse-button events in the protected top strip are suppressed so the system cursor cannot appear there, while motion events continue through unchanged.
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
./scripts/test_binary_compatibility.sh ./bin/game-cursor-fence
./scripts/test_companion_defaults.sh ./bin/game-cursor-fence
./scripts/test_provider_detection.sh ./bin/game-cursor-fence
./scripts/test_capture_model.sh ./bin/game-cursor-fence
```

The repository also contains macOS HID and Wine Raw Input probes used for end-to-end cursor regression testing.

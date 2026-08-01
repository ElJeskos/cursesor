# Game Cursor Fence portable installer

The release DMG contains one graphical application named `Install Game Cursor Fence.app`.
That installer bundles the universal Game Cursor Fence application and installs it for the current macOS user without administrator privileges.

## Runtime behavior

Game Cursor Fence runs in the background for frontmost GameHub and CrossOver games.
It prevents a click in the protected top strip from exposing the macOS system cursor and keeps vertical game-camera movement independent of the physical display boundary.
Normal motion reaches Wine unchanged, without a live boundary warp or synthetic diagonal movement.

## Compatibility

- macOS 11 or later.
- Apple silicon and Intel Macs.
- Windows games launched through GameHub or CrossOver.

## Installation

1. Open the downloaded DMG.
2. Control-click `Install Game Cursor Fence.app`, choose **Open**, and confirm the launch.
3. Click **Install** in the graphical installer.
4. Enable Game Cursor Fence in **Privacy & Security → Accessibility**.
5. Enable Game Cursor Fence in **Privacy & Security → Input Monitoring**.
6. Return to the installer and click **Check Again**.

The installer places the application at `~/Applications/Game Cursor Fence.app` and creates `~/Library/LaunchAgents/local.game-cursor-fence.plist`.
No administrator password is required.

## Gatekeeper

The personal release is signed with a local code-signing certificate and is not notarized by Apple.
The first launch can therefore require the Control-click **Open** action.
The installer removes quarantine only from its bundled Game Cursor Fence application and never disables Gatekeeper globally.

## Removal

The bundled backend preserves an older installation before replacement.
The standalone `packaging/Uninstall.command` helper stops the LaunchAgent and moves the installed app and plist to the Trash.
Runtime logs remain under `~/.local/state/game-cursor-fence`.

## Build a DMG

The standard packaging command rebuilds and installs the current source before creating the disk image:

```bash
./scripts/package_portable.sh
```

To package an already installed and verified app without replacing it, use:

```bash
GCF_SKIP_BUILD_INSTALL=true \
GCF_SOURCE_APP="$HOME/Applications/Game Cursor Fence.app" \
GCF_OUTPUT_DIR="$PWD/dist" \
./scripts/package_portable.sh
```

Set `GCF_EXPECT_SOURCE_SHA256` to require an exact executable hash before packaging.

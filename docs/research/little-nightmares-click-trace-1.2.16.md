# Little Nightmares III: 1.2.16 click delivery failure

## Reproduction (2026-10-04)

User ran Little Nightmares III through CrossOver and compared physical left clicks at the upper boundary with clicks slightly below. Only below-strip clicks worked. With user approval, the installed helper was restarted with its existing `--debug-log-file` option; no binary/source changes or game restart were performed.

Trace: `~/.local/state/game-cursor-fence/click-diagnosis-20261004T184958/click-debug.log`.

At monotonic times 368311.611–368313.234, the log records five complete left down/up pairs (`type=1`/`type=2`) forwarded to PID 97164, the running `SMG031MP/Binaries/Win64/LittleNightmaresIII.exe` process:

```text
capture-top-click-forwarded targetPid=97164 old=(313.8,0.0) new=(313.8,37.0) type=1
capture-top-click-forwarded targetPid=97164 old=(313.8,0.0) new=(313.8,37.0) type=2
```

Capture was active throughout those clicks. No no-target or tap-timeout report occurred during those pairs. Subsequent motion reached approximately y=84.9; the user reports below-strip clicks worked. Ordinary buttons are not individually logged, so their exact coordinates/count cannot be recovered from this trace.

## What this proves / does not prove

The protected-region predicate, foreground gate, allocation and PID posting branch execute for both halves of the click. The original is suppressed and the copy is submitted at safe screen coordinates. `CGEventPostToPid` returns void: the word `forwarded` is not an acknowledgment by Wine or the game.

The callback test passes with SDK MacOSX26.5 but mocks `CGEventPostToPid`; it cannot reproduce the delivery failure downstream of that call. It is not a gameplay regression test.

Still-unresolved candidates, in investigation order:

1. PID-targeted events do not enter the Wine input route used by this game. Compare against a safe-coordinate event traversing normal routing, measuring receipt inside Wine.
2. Copied events retain stale window metadata despite changing screen location. Compare a copied event with a fresh event under otherwise identical conditions.
3. The helper lacks synthetic posting permission despite having an operational interception tap. Query preflight permission inside the helper's own signed identity; permission results from a separate test binary do not establish the installed helper's permission.

Do not claim a specific candidate is proven by this log. Do not replace the camera/motion algorithm or inject global test clicks into the live game without a controlled test.

## Cleanup and next step

The diagnostic launchd job was unloaded and the unchanged permanent `~/Library/LaunchAgents/local.game-cursor-fence.plist` was bootstrapped. Normal helper PID at verification: 13400. No permanent plist or installed binary changes were made. Diagnostic artifacts are retained for comparison.

Existing `scripts/test_wine_top_motion.sh` explicitly refuses to run while a real matching game is running. It also targets GameHub by default and must not be presented as CrossOver validation without adaptation. Next step needs the game closed so a controlled receiving-side Wine probe can be prepared/run without competing with live gameplay. Ultimate acceptance remains physical top clicks in Little Nightmares III, with no system arrow or camera regression.

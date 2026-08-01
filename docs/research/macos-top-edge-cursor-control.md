# Preventing the macOS System Cursor from Appearing at the Top Edge

Date: 2026-07-24.

## Research question

The required behavior is to let a frontmost Wine or Unity game continue receiving relative vertical mouse movement and matching mouse-down and mouse-up events when the pointer reaches the top of a macOS display.

The macOS system arrow must not replace or hide the game's cursor, the frontmost game must not lose focus, and no cursor warp may make the camera jump.

This note uses Apple documentation, Apple public SDK semantics, Unity documentation, and current Wine source as primary evidence.

## Executive conclusion

The problem has four independent pieces of state: the WindowServer cursor coordinate, the displayed cursor image and hide count, the active application or cursor owner, and the process that receives an input event.

Changing only one of those pieces does not implicitly change the other three, as shown by Apple's separate APIs for event location, cursor hiding, foreground presentation, and process-targeted event posting ([event location](https://developer.apple.com/documentation/coregraphics/cgevent/location?language=objc), [cursor control](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/MouseCursor.html), [presentation options](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.property?language=objc), [process posting](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid%28_%3A%29?language=objc)).

The strongest external-helper candidate is preemptive, stateful edge capture.

It should disassociate physical mouse motion before the WindowServer cursor enters the menu-bar region, preserve the original movement deltas and button events, and remain latched until a real downward escape or focus loss.

This candidate addresses the cursor coordinate that causes menu-bar hit testing instead of trying to hide the resulting arrow.

The implementation must not re-associate merely because `CGCursorIsVisible` changes, because Apple exposes that deprecated function only as a Boolean visibility query and it cannot distinguish a game hand from the macOS arrow ([CGCursorIsVisible](https://developer.apple.com/documentation/coregraphics/cgcursorisvisible%28%29), [NSCursor.currentSystem](https://developer.apple.com/documentation/appkit/nscursor/currentsystem)).

The strongest button-only fallback is to delete the original top-edge down and up events in an active event tap and post copies directly to the verified Wine PID with `CGEventPostToPid`.

Direct PID replay changes delivery but does not move or confine the WindowServer cursor, so it succeeds only if suppressing the original click is enough to prevent the arrow from appearing.

The most standards-aligned long-term solution is code inside the foreground Wine or game process, because Apple documents cursor disassociation, hiding, and application presentation as foreground-application facilities ([Apple cursor-control guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/MouseCursor.html), [presentationOptions](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.property?language=objc)).

## The four state domains

### 1. Cursor coordinates

`CGEventGetLocation` returns a mouse event's location in global display coordinates, while `CGEventSetLocation` changes that event field in the same coordinate space ([CGEventGetLocation](https://developer.apple.com/documentation/coregraphics/cgevent/location?language=objc), [CGEventSetLocation](https://developer.apple.com/documentation/coregraphics/cgeventsetlocation?language=objc)).

The horizontal and vertical delta fields are separate event fields that represent movement since the previous mouse movement event ([CGEventField](https://developer.apple.com/documentation/coregraphics/cgeventfield?language=objc)).

Changing an event's absolute location therefore does not, by documented contract, require changing its delta fields.

`CGWarpMouseCursorPosition` moves the WindowServer cursor once and does not generate or post a mouse event ([CGWarpMouseCursorPosition](https://developer.apple.com/documentation/coregraphics/cgwarpmousecursorposition%28_%3A%29)).

A warp is a one-shot move rather than confinement.

### 2. Cursor visibility and image

`CGDisplayHideCursor` increments a hide count, and `CGDisplayShowCursor` decrements that count and shows the cursor only when the count reaches zero ([CGDisplayHideCursor](https://developer.apple.com/documentation/coregraphics/cgdisplayhidecursor%28_%3A%29), [CGDisplayShowCursor](https://developer.apple.com/documentation/coregraphics/cgdisplayshowcursor%28_%3A%29)).

Apple requires hide and show calls to be balanced and documents cursor control as a foreground-application facility ([Apple cursor-control guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/MouseCursor.html)).

`NSCursor.current` describes the cursor stack set by the calling application and may not be the cursor visible on screen when another application is active ([NSCursor.current](https://developer.apple.com/documentation/appkit/nscursor/current)).

`NSCursor.currentSystem` can describe the current system cursor regardless of which app set it, but Apple has deprecated it and recommends ScreenCaptureKit for screen capture ([NSCursor.currentSystem](https://developer.apple.com/documentation/appkit/nscursor/currentsystem)).

Visibility and cursor image are therefore unsuitable as ownership signals for a background fence.

### 3. Focus and ownership

Apple says the cursor-control functions in its Quartz Display Services guide require the calling application to be foreground ([Apple cursor-control guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/MouseCursor.html)).

`NSApplication.presentationOptions` likewise describes options that apply when that same application is active ([presentationOptions](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.property?language=objc)).

A separate background helper is consequently outside the documented ownership model when it tries to impose cursor association, cursor hiding, or presentation behavior on Wine.

That does not prove the calls will fail on a tested macOS release, but it makes their cross-process behavior an empirical compatibility dependency rather than a documented guarantee.

### 4. Event delivery

An active event tap may pass an event, modify it, replace it, or return `NULL` to delete it ([CGEventTapCallBack](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback), [CGEventTapOptions](https://developer.apple.com/documentation/coregraphics/cgeventtapoptions)).

`CGEventPost` inserts an event back into the general stream at a selected tap location, where downstream taps see it ([CGEventPost](https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29?language=objc)).

`CGEventTapPostEvent` similarly posts from a tap at the point where a returned event would continue through the stream ([CGEventTapPostEvent](https://developer.apple.com/documentation/coregraphics/cgevent/tappostevent%28_%3A%29)).

Apple documents process-targeted posting as a routing-policy mechanism that lets a system-wide tap redirect an event to another process, and `CGEventPostToPid` is the current PID-based entry point ([process-routing semantics](https://developer.apple.com/documentation/coregraphics/cgevent/posttopsn%28processserialnumber%3A%29?language=objc), [CGEventPostToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid%28_%3A%29?language=objc)).

Changing delivery does not change the physical cursor coordinate or its image.

## Mechanism comparison

| Mechanism | Primary control | Relative motion | Cursor image | Top click | Assessment |
| --- | --- | --- | --- | --- | --- |
| Preemptive edge capture with `CGAssociateMouseAndMouseCursorPosition(false)` | Physical cursor coordinate | Preserves X/Y deltas by contract | Unchanged by the association API | Original down/up can pass | Best external root-cause candidate, but background-helper ownership is not documented |
| Delete original and `CGEventPostToPid` | Destination process | Untouched | Untouched | Explicitly routed to Wine | Best button-only fallback and diagnostic |
| Modify event location and warp | Event and physical coordinates | Requires careful delta compensation | May visibly move | Original event can pass | Higher jitter and camera-jump risk |
| `CGDisplayHideCursor` or `NSCursor.hide` | Visibility only | Untouched | Hides the game cursor too when it is a hardware cursor | Does not reroute the click | Reject as the main solution |
| Native fullscreen default | Window presentation | Untouched | Unchanged | Menu bar can reappear at top | Insufficient |
| `hideMenuBar` plus `hideDock` | System UI presentation | Untouched | Unchanged | Removes the menu-bar target | Strong in-process option only |
| Wine's `setMouseConfinementRect:` path | Rectangular cursor coordinate | Wine-managed | Wine-managed | Original event can pass | Undocumented AppKit API and unavailable to a separate process |
| Virtual IOHID device | New device-level input | Physical-device semantics | Unchanged | Still enters global routing | Useful for E2E input, not a preferred runtime fix |
| Unity `CursorLockMode.Locked` | Game-owned cursor lock | Engine-managed | Cursor hidden while locked | Game-owned | Best when the game itself can be changed |

## Stateful preemptive edge capture

### Documented foundation

`CGAssociateMouseAndMouseCursorPosition(false)` prevents physical mouse movement from changing the cursor position while delivered events retain delta updates ([CGAssociateMouseAndMouseCursorPosition](https://developer.apple.com/documentation/coregraphics/cgassociatemouseandmousecursorposition%28_%3A%29)).

Apple explicitly presents that API as the relative-input mechanism for a foreground application and says `true` reverses the effect ([Apple cursor-control guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/MouseCursor.html)).

The API changes coordinate association and does not document any change to cursor visibility or cursor image.

This separation is why the helper should not call hide or show as part of edge capture.

### Wine precedent

Wine states that neither public Quartz nor public Cocoa has an exact general analogue of Win32 cursor clipping ([Wine cursor-clipping source, lines 29–43](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L29-43)).

Wine's public-API fallback disassociates the mouse and cursor, accumulates a synthetic location from delta fields, clips that location, and modifies the event stream before Cocoa assigns a window ([Wine cursor-clipping source, lines 46–67](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L46-67), [lines 199–268](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L199-268)).

Wine uses an annotated-session event tap because it needs to modify locations before events enter Cocoa, including cases involving other processes such as Mission Control ([Wine cursor-clipping source, lines 278–318](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L278-318)).

Wine also records each warp and subtracts the warp displacement from later delta fields because Wine observed that a warp can be reflected in a subsequent movement delta while the cursor is disassociated ([Wine cursor-clipping source, lines 60–67](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L60-67), [lines 135–166](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L135-166), [lines 224–245](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L224-245)).

That source validates the general disassociate-plus-delta design and also explains why repeated warping is dangerous for camera motion.

### Recommended external state

The helper should remember the last known safe cursor location while the target game is frontmost.

On an upward movement whose proposed location enters the guard band, the tap should enter `EDGE_CAPTURED` before returning that event.

If one fast movement proposes a location above the safe boundary, the callback should set that same event's location to the safe boundary while leaving the original delta fields unchanged.

The callback should disassociate once, before the modified event continues, so the physical cursor remains at the last safe location.

This ordering is a falsifiable implementation hypothesis because Apple documents event-location modification and disassociation separately but does not specify their exact WindowServer presentation timing ([CGEventSetLocation](https://developer.apple.com/documentation/coregraphics/cgeventsetlocation?language=objc), [CGAssociateMouseAndMouseCursorPosition](https://developer.apple.com/documentation/coregraphics/cgassociatemouseandmousecursorposition%28_%3A%29)).

While `EDGE_CAPTURED` is active, movement and button events should retain their original deltas, button numbers, click state, pressure, and ordering.

The state must not exit merely because `CGCursorIsVisible` becomes true.

The state should exit when the target game loses frontmost status, exits, the tap is disabled, or accumulated downward movement crosses a release boundary with hysteresis.

`CGEventTapEnable` documents that an unresponsive or user-disabled tap can be re-enabled, so the cleanup path must re-associate before or while recovering from either disable notification ([CGEventTapEnable](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable%28tap%3Aenable%3A%29), [tap-disabled event types](https://developer.apple.com/documentation/coregraphics/cgeventtype)).

Disassociation freezes both axes of the WindowServer cursor, not only the vertical axis, because Apple describes the delivered X and Y locations as constant while both delta fields continue updating ([CGAssociateMouseAndMouseCursorPosition](https://developer.apple.com/documentation/coregraphics/cgassociatemouseandmousecursorposition%28_%3A%29)).

That behavior is suitable for relative camera control but can temporarily freeze a visible hardware cursor in an absolute menu.

The release threshold must therefore be short for a visible absolute-cursor phase, or the feature must use a per-game input-mode profile instead of guessing from deprecated visibility state.

### Fast-crossing requirement

Entering capture only after observing a cursor already at the menu bar is too late to guarantee that the system did not claim the cursor.

The guard must be inside the safe game region, and the event that crosses the guard must be corrected before it continues.

The guard should be derived from the target screen rather than a fixed desktop-union Y value.

`NSScreen.frame` includes menu-bar and Dock space, while `NSScreen.visibleFrame` excludes the areas occupied by the menu bar and Dock and adapts to current UI settings ([NSScreen.frame](https://developer.apple.com/documentation/appkit/nsscreen/frame), [NSScreen.visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)).

The screen list can change dynamically and must not be cached indefinitely ([NSScreen.screens](https://developer.apple.com/documentation/appkit/nsscreen/screens)).

## Suppress and repost button events

### Why it is attractive

An active tap can return `NULL` to prevent the physical top-edge down or up event from continuing to the menu bar ([CGEventTapCallBack](https://developer.apple.com/documentation/coregraphics/cgeventtapcallback)).

The helper can copy the original event and post it directly to the verified foreground Wine PID with `CGEventPostToPid` ([CGEvent.copy](https://developer.apple.com/documentation/coregraphics/cgevent/copy%28%29), [CGEventPostToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid%28_%3A%29?language=objc)).

Apple's process-routing documentation explicitly gives the pattern of tapping an annotated-session event and posting it to a chosen process ([CGEventPostToPSN routing discussion](https://developer.apple.com/documentation/coregraphics/cgevent/posttopsn%28processserialnumber%3A%29?language=objc)).

This path need not warp the pointer, synthesize a movement event, alter the game's cursor image, or modify a movement delta.

It is therefore the lowest-side-effect experiment for a failure caused specifically by the menu bar handling the click.

### Why it is not full confinement

The preceding motion can already move the WindowServer cursor into a system-owned region before a button event exists.

`CGEventPostToPid` changes the receiver of an event but has no documented effect on cursor location, association, image, or active-application presentation ([CGEventPostToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid%28_%3A%29?language=objc)).

Direct replay cannot remove an arrow that appeared during the preceding movement.

It should therefore rank below preemptive edge capture as a general solution, while remaining the preferred fallback when motion capture would harm a visible absolute cursor.

### Replay correctness

The helper should copy rather than reconstruct each button event so it preserves the original fields by default ([CGEvent.copy](https://developer.apple.com/documentation/coregraphics/cgevent/copy%28%29)).

Apple documents that matching down and up events share a mouse event number and that click state carries single-, double-, or triple-click semantics ([mouse event number](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventnumber), [click state](https://developer.apple.com/documentation/coregraphics/cgeventfield/mouseeventclickstate)).

The replay should carry a unique `kCGEventSourceUserData` tag so the helper can reject its own synthetic events ([CGEventField](https://developer.apple.com/documentation/coregraphics/cgeventfield?language=objc)).

The down and up pair must remain bound to the same target PID even if focus changes between them, or the helper must synthesize a balancing up during cleanup to avoid a stuck game button.

The target PID must be checked as frontmost immediately before suppressing the original event.

`CGEventPost` and `CGEventTapPostEvent` are weaker candidates because they re-enter the general event stream rather than selecting the Wine process ([CGEventPost](https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29?language=objc), [CGEventTapPostEvent](https://developer.apple.com/documentation/coregraphics/cgevent/tappostevent%28_%3A%29)).

### Event-tap constraints

Apple documents event taps as filters that run before delivery to a foreground application ([Quartz Event Services](https://developer.apple.com/documentation/coregraphics/quartz-event-services)).

Apple's `CGEventTapCreate` page says only root can place a tap at the HID entry point and that unavailable event types can be removed from the requested mask ([CGEventTapCreate](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29?language=objc)).

A non-root helper must therefore verify whether its session or annotated-session tap intercepts the event early enough on the tested macOS release.

Wine's own fallback uses an annotated-session tap and notes that event-tap clipping requires Accessibility permission on Catalina and later ([Wine cursor-clipping source, lines 296–318](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L296-318), [lines 389–407](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L389-407)).

The callback must remain short because Apple can disable an unresponsive tap and report that state through a tap-disabled event ([CGEventTapEnable](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable%28tap%3Aenable%3A%29), [tapDisabledByTimeout](https://developer.apple.com/documentation/coregraphics/cgeventtype/tapdisabledbytimeout)).

## Clamping and warping

`CGDisplayMoveCursorToPoint` and `CGWarpMouseCursorPosition` move the cursor without generating a mouse event ([CGDisplayMoveCursorToPoint](https://developer.apple.com/documentation/coregraphics/cgdisplaymovecursortopoint%28_%3A_%3A%29), [CGWarpMouseCursorPosition](https://developer.apple.com/documentation/coregraphics/cgwarpmousecursorposition%28_%3A%29)).

Apple specifically mentions recentering by games that do not want a cursor pinned by display edges ([CGWarpMouseCursorPosition](https://developer.apple.com/documentation/coregraphics/cgwarpmousecursorposition%28_%3A%29)).

The absence of a generated event does not prove that a game polling absolute position will ignore the changed coordinate.

Wine's need to compensate later deltas after each warp is direct evidence that warp side effects must be handled in a relative-input design ([Wine cursor-clipping source, lines 60–67](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L60-67)).

Repeated clamp or recenter warps are therefore a lower-ranked solution for this project because the reported camera jerk is consistent with an uncorrected coordinate or delta transition.

A single same-event location correction before latching association is preferable to a separate cursor warp, provided the HORSES experiment proves that the WindowServer never displays the unsafe location.

## Hiding and showing the cursor

Hiding changes only whether the current cursor is drawn and does not alter its coordinate or event target ([CGDisplayHideCursor](https://developer.apple.com/documentation/coregraphics/cgdisplayhidecursor%28_%3A%29), [CGEventGetLocation](https://developer.apple.com/documentation/coregraphics/cgevent/location?language=objc)).

An invisible cursor can therefore still be positioned over the menu-bar region for hit testing.

If HORSES uses a hardware cursor for its hand, a global hide operation hides the desired hand as well as the unwanted arrow.

Even when a game draws a software cursor, hiding alone does not guarantee that a top click remains routed to the game.

`NSCursor.hide` also requires balanced `unhide` calls and affects whichever cursor becomes current until it is balanced ([NSCursor.hide](https://developer.apple.com/documentation/appkit/nscursor/hide%28%29), [NSCursor.unhide](https://developer.apple.com/documentation/appkit/nscursor/unhide%28%29)).

The fence should not participate in another process's hide count.

Re-hiding after the click is also too late to guarantee that the arrow was not displayed for one frame or that the menu bar did not receive the event.

Hide and show APIs are suitable only for a controlled in-process game implementation that owns the full hide-count lifecycle.

## Fullscreen and menu-bar presentation

Native AppKit fullscreen auto-hides the menu bar by default, but Apple says the menu bar reappears when the pointer reaches the top of the display ([Apple fullscreen guide](https://developer.apple.com/library/archive/documentation/General/Conceptual/MOSXAppProgrammingGuide/FullScreenApp/FullScreenApp.html)).

`autoHideMenuBar` has the same near-edge behavior by definition ([NSApplicationPresentationAutoHideMenuBar](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct/autohidemenubar)).

`hideMenuBar` makes the menu bar entirely hidden and disabled, and Apple requires it to be combined with `hideDock` ([NSApplicationPresentationHideMenuBar](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct/hidemenubar), [presentation-option combinations](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.struct)).

Those options apply while the application that owns them is active ([presentationOptions](https://developer.apple.com/documentation/appkit/nsapplication/presentationoptions-swift.property?language=objc)).

Setting them in the background fence cannot, by documented contract, impose them on the frontmost Wine application.

Applying `hideMenuBar | hideDock` inside Wine is nevertheless a strong in-process solution for a true fullscreen game.

It is not appropriate for ordinary windowed games or game menus that intentionally expose system UI.

## Cursor confinement APIs that actually exist

Apple's public cursor-control surface provides hide, show, association, and one-shot cursor moves, but it does not document a public rectangular equivalent of Win32 `ClipCursor` ([Apple cursor-control guide](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/QuartzDisplayServicesConceptual/Articles/MouseCursor.html)).

Wine explicitly reaches the same conclusion in its macOS driver source ([Wine cursor-clipping source, lines 29–38](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L29-38)).

Wine uses `-[NSWindow setMouseConfinementRect:]` on macOS 10.13 and later but labels it undocumented ([Wine cursor-clipping source, lines 389–421](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L389-421)).

Wine also documents that the confinement rectangle is tied to a particular visible window and cannot express arbitrary off-window clipping ([Wine cursor-clipping source, lines 389–400](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L389-400)).

The current Wine driver selects that private path by default when the selector exists and otherwise retains the event-tap implementation ([Wine cursor-clipping source, lines 425–490](https://gitlab.winehq.org/wine/wine/-/blob/b41409d9be509207c16d814742ceb8273bc201fc/dlls/winemac.drv/cocoa_cursorclipping.m#L425-490)).

A separate helper cannot safely invoke an undocumented method on another process's `NSWindow` object.

The private method should not become a dependency of Game Cursor Fence.

Unity's public `CursorLockMode.Confined` is unsupported on macOS, while `CursorLockMode.Locked` centers the pointer and makes it invisible ([Unity Cursor.lockState](https://docs.unity3d.com/current/ScriptReference/Cursor-lockState.html)).

Unity's locked mode is an appropriate game-side camera-control state but cannot be imposed externally on an unmodified game.

## IOHID-level injection

Apple exposes a virtual HID-device API whose report function dispatches a report on behalf of that device ([IOHIDUserDeviceHandleReportWithTimeStamp](https://developer.apple.com/documentation/iokit/3334955-iohiduserdevicehandlereportwitht?language=objc)).

Creating a virtual HID device requires the `com.apple.developer.hid.virtual.device` entitlement ([virtual HID entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.hid.virtual.device)).

A virtual mouse report enters the input pipeline as new device-level input rather than selecting a destination game process, which follows from Apple's distinction between device-originated Quartz events and process-targeted posting ([CGEvent overview](https://developer.apple.com/documentation/coregraphics/cgevent), [CGEventPostToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid%28_%3A%29?language=objc)).

IOHID injection does not suppress the original physical click and does not itself confine the system cursor.

Using it at runtime would still require an event tap or device-filtering layer and would add a global synthetic pointer source.

IOHID is valuable for realistic E2E input generation because it exercises the same top-edge behavior as a physical mouse.

It is not the preferred production fix.

## Synthetic-event suppression settings

`CGEventSourceSetLocalEventsSuppressionInterval` configures how long local hardware events may be suppressed after a Quartz event from that source is posted, and Apple documents a default interval of 0.25 seconds ([CGEventSourceSetLocalEventsSuppressionInterval](https://developer.apple.com/documentation/coregraphics/cgeventsourcesetlocaleventssuppressioninterval)).

`CGEventSourceSetLocalEventsFilterDuringSuppressionState` controls which local event classes remain enabled during that interval or a synthetic drag ([suppression-state filter](https://developer.apple.com/documentation/coregraphics/cgeventsource/setlocaleventsfilterduringsuppressionstate%28_%3Astate%3A%29)).

These APIs do not control cursor visibility, cursor association, confinement, focus, or process routing.

A replay implementation should explicitly avoid suppressing the user's matching physical up event.

## Project-specific interpretation

The current source dynamically resolves deprecated `CGCursorIsVisible`, detaches only while it reports false, and re-associates in both the event callback and maintenance path as soon as it reports true ([current source, visibility and maintenance](../../src/game-cursor-fence.c#L557-L615), [current source, capture callback](../../src/game-cursor-fence.c#L656-L686)).

That policy treats all visible cursors as equivalent even though the required game hand and the unwanted macOS arrow are both visible cursor images.

It also makes a latched relative-input state vulnerable to immediate release when the displayed cursor changes for reasons outside the fence.

The capture decision should instead be based on edge-entry direction, target focus, and explicit state transitions.

The current clamp path repeatedly changes event location, which is a coordinate policy rather than a relative-input state machine ([current source, clamp path](../../src/game-cursor-fence.c#L722-L727)).

The supplied `Game-Cursor-Fence-1.2.4-macOS-universal.dmg` artifact contains diagnostic names for safe parking, cursor hiding, watchdog re-hiding, and top-click forwarding.

That artifact is local binary evidence rather than source-level proof of exact behavior.

The reported cursor teleport and camera jerk in that family of approaches strengthen the case for avoiding repeated warp and hide/show operations.

## Recommended state machine

### `INACTIVE`

The target game is absent or not frontmost.

The tap passes all events unchanged.

Any association state owned by the helper is restored exactly once with `CGAssociateMouseAndMouseCursorPosition(true)`.

The helper does not call show or unhide because it does not own the game's hide count.

### `ARMED`

The target Wine PID is verified frontmost, and the helper continually records the last safe event location on the target screen.

All movement and button events pass unchanged while the proposed location remains below the guard.

The guard is derived from the current target screen's frame and visible frame rather than a fixed desktop coordinate ([NSScreen.frame](https://developer.apple.com/documentation/appkit/nsscreen/frame), [NSScreen.visibleFrame](https://developer.apple.com/documentation/appkit/nsscreen/visibleframe)).

### `EDGE_CAPTURED`

An upward event has proposed entry into the guard.

The callback first records the original X/Y deltas.

It disassociates once and, only for a one-event fast crossing, corrects that same event's absolute location to the safe boundary.

It returns the event with original deltas and original type.

Subsequent movement and button events pass with their original deltas and button fields while the WindowServer cursor remains at the safe anchor.

Visibility changes do not release this state.

Accumulated positive Y delta beyond a hysteresis threshold releases the state without a warp.

Focus loss, game exit, or tap disable also releases it and clears button state.

### `EDGE_BUTTON_REDIRECT`

This state is used when a button event arrives in the risk band without a successful preemptive capture, or when a per-game profile forbids disassociation for a visible absolute cursor.

The callback copies the event, tags the copy, verifies the target PID again, returns `NULL`, and posts the copy with `CGEventPostToPid`.

The matching up event is routed to the same PID exactly once.

No mouse-moved event, cursor warp, hide, show, association change, or presentation change occurs in this state.

### `RECOVERY`

The helper re-associates only if it previously disassociated.

It re-enables a disabled tap after clearing transient state ([CGEventTapEnable](https://developer.apple.com/documentation/coregraphics/cgevent/tapenable%28tap%3Aenable%3A%29)).

It ensures that every redirected down has a matching up and that no synthetic event can re-enter the redirect path.

It then returns to `INACTIVE` or `ARMED` based on verified foreground state.

## Falsifiable HORSES experiments

### Experiment 0: Baseline

Bring HORSES to its main menu, establish the visible hand cursor, move to the top edge, and click once.

Record the frontmost PID, event target PID, event locations, delta fields, physical cursor location, downstream down/up count, and cursor-inclusive versus cursor-excluded captures.

The current bug is reproduced only if the macOS arrow appears after the click while HORSES was frontmost.

ScreenCaptureKit exposes a `showsCursor` switch for deterministic cursor-inclusive and cursor-excluded captures ([SCStreamConfiguration.showsCursor](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/showscursor), [SCScreenshotConfiguration.showsCursor](https://developer.apple.com/documentation/screencapturekit/scscreenshotconfiguration/showscursor)).

### Experiment 1: Suppress only

Return `NULL` for the top-edge down and up without replaying them.

If the arrow does not appear, the physical click's downstream handling is a necessary trigger and direct PID routing remains plausible.

If the arrow still appears, button-only routing is falsified and the cursor must be kept out of the system region before the click.

### Experiment 2: General-stream replay

Suppress the original pair and replay the copies with `CGEventPost`.

If the arrow reappears, general WindowServer routing is the wrong replay path.

This result would be consistent with Apple's documentation that `CGEventPost` inserts the event into the general stream ([CGEventPost](https://developer.apple.com/documentation/coregraphics/cgevent/post%28tap%3A%29?language=objc)).

### Experiment 3: PID replay

Suppress the original pair and replay unchanged copies with `CGEventPostToPid(HORSES_PID, event)`.

This experiment passes only if HORSES remains frontmost, receives exactly one matching down/up pair, retains its hand cursor, and never shows the macOS arrow.

It also requires zero movement events, zero cursor displacement, and zero camera displacement.

If Wine ignores the unchanged y-coordinate, repeat once with only the replay event's absolute y clamped to the safe boundary.

Do not warp the physical cursor in either variant.

### Experiment 4: Preemptive edge capture

From a safe location, inject one upward movement large enough to cross the guard in a single event.

Enter `EDGE_CAPTURED`, preserve the original negative Y delta, and correct only that event's absolute location.

Continue sending upward deltas and confirm that the game still receives them while the physical cursor remains safe.

Click once and require one unchanged downstream down/up pair with no arrow, no hand disappearance, no warp, and no focus change.

Then send downward deltas and require release only after the configured hysteresis.

This experiment falsifies the candidate if horizontal input stops in a game phase that requires an absolute cursor, if the hand disappears, if the physical cursor reaches the menu bar, or if the camera jumps.

### Experiment 5: In-process control

If both external candidates fail, test the same association state machine from inside the foreground Wine process.

Separately test `hideMenuBar | hideDock` inside Wine's fullscreen lifecycle.

Success in-process and failure from the helper would confirm that foreground ownership, rather than the API concept itself, is the external architecture's limiting factor.

## Acceptance criteria

HORSES remains the frontmost application before, during, and after the click.

The game receives exactly one down and one matching up.

The macOS arrow never appears in cursor-inclusive capture.

The HORSES hand does not disappear or change shape.

The physical cursor does not teleport.

No synthetic mouse-moved event is introduced by a button-only solution.

Upward relative deltas continue reaching the game after the physical cursor reaches the protected edge.

The camera does not move in response to a warp, replay, or association transition.

Downward escape, focus loss, game exit, and tap disable all restore normal association without changing another process's cursor hide count.

## Ranked recommendation

1. Implement and test preemptive `EDGE_CAPTURED` latching without visibility-based release, repeated warp, or hide/show calls.

2. Use suppress-plus-`CGEventPostToPid` as the fallback for top-edge buttons and as the diagnostic that separates menu-bar click handling from cursor-coordinate ownership.

3. Move the state machine into Wine if external calls prove unreliable under the documented foreground-ownership rules.

4. Use in-process `hideMenuBar | hideDock` only for true fullscreen games whose system UI should be completely unavailable.

5. Retain IOHID injection for E2E tests rather than production routing.

6. Reject hide-only, repeated-warp, and undocumented cross-process confinement solutions.

/* Exercise the Quartz event-tap callback seam. Only OS output/foreground
 * boundaries are substituted: no input is posted and no real cursor is moved. */
#include <ApplicationServices/ApplicationServices.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

static pid_t probe_frontmost_pid = 1234;
static unsigned probe_cursor_operations = 0;
static unsigned probe_post_count = 0;
static CGEventRef probe_posted_events[64];
static pid_t probe_posted_pids[64];
static unsigned probe_tap_post_count = 0;

static void __attribute__((unused)) probe_tap_post(CGEventTapProxy proxy, CGEventRef event) {
    if (proxy != (CGEventTapProxy)&probe_post_count || probe_post_count >= 64) abort();
    probe_posted_pids[probe_post_count] = probe_frontmost_pid;
    probe_posted_events[probe_post_count++] = CGEventCreateCopy(event);
    probe_tap_post_count++;
}

static void __attribute__((unused)) probe_post_to_pid(pid_t pid, CGEventRef event) {
    if (probe_post_count >= 64) abort();
    probe_posted_pids[probe_post_count] = pid;
    probe_posted_events[probe_post_count++] = CGEventCreateCopy(event);
}

static pid_t probe_frontmost_application_pid(void) { return probe_frontmost_pid; }
static CGError probe_warp(CGPoint point) { (void)point; probe_cursor_operations++; return kCGErrorSuccess; }
static CGError probe_associate(bool connected) { (void)connected; probe_cursor_operations++; return kCGErrorSuccess; }
static CGError probe_hide(CGDirectDisplayID display) { (void)display; probe_cursor_operations++; return kCGErrorSuccess; }
static CGError probe_show(CGDirectDisplayID display) { (void)display; probe_cursor_operations++; return kCGErrorSuccess; }

#define main gcf_application_main
#define CGEventPostToPid probe_post_to_pid
#define CGEventTapPostEvent probe_tap_post
#define CGWarpMouseCursorPosition probe_warp
#define CGAssociateMouseAndMouseCursorPosition probe_associate
#define CGDisplayHideCursor probe_hide
#define CGDisplayShowCursor probe_show
#define gcf_frontmost_application_pid probe_frontmost_application_pid
#include "../src/game-cursor-fence.c"
#undef main
#undef CGEventPostToPid
#undef CGEventTapPostEvent
#undef CGWarpMouseCursorPosition
#undef CGAssociateMouseAndMouseCursorPosition
#undef CGDisplayHideCursor
#undef CGDisplayShowCursor
#undef gcf_frontmost_application_pid

static bool probe_cursor_is_visible(void) { return false; }
static unsigned failures = 0;

static void expect(bool condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        failures++;
    }
}

static CGEventRef make_button(CGEventType type, double x, double y, int64_t click_count) {
    CGMouseButton button = type == kCGEventRightMouseDown || type == kCGEventRightMouseUp ? kCGMouseButtonRight :
        (type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp ? kCGMouseButtonCenter : kCGMouseButtonLeft);
    CGEventRef event = CGEventCreateMouseEvent(NULL, type, CGPointMake(x, y), button);
    if (!event) abort();
    CGEventSetIntegerValueField(event, kCGMouseEventClickState, click_count);
    CGEventSetIntegerValueField(event, kCGMouseEventNumber, 88);
    CGEventSetIntegerValueField(event, kCGEventSourceUserData, 0x54455354);
    CGEventSetFlags(event, kCGEventFlagMaskShift);
    CGEventSetDoubleValueField(event, kCGMouseEventPressure, 0.75);
    return event;
}

static CGEventRef deliver(CGEventType type, CGEventRef event) {
    CGEventTapCallBack callback = cursor_event_callback;
    return callback((CGEventTapProxy)&probe_post_count, type, event, NULL);
}

static void clear_posted_events(void) {
    for (unsigned i = 0; i < probe_post_count; i++) CFRelease(probe_posted_events[i]);
    probe_post_count = 0;
    probe_tap_post_count = 0;
    probe_cursor_operations = 0;
}

static void top_click_reaches_game_once(void) {
    const double base = top_fence_y() - 36.0;
    CGEventRef down = make_button(kCGEventLeftMouseDown, 321.0, base + 33.0, 2);
    CGEventRef up = make_button(kCGEventLeftMouseUp, 321.0, base + 33.0, 2);
    CGEventTapCallBack callback = cursor_event_callback;
    expect(callback((CGEventTapProxy)&probe_post_count, kCGEventLeftMouseDown, down, NULL) == NULL,
           "unsafe original down must not enter macOS routing");
    expect(callback((CGEventTapProxy)&probe_post_count, kCGEventLeftMouseUp, up, NULL) == NULL,
           "unsafe original up must not enter macOS routing");
    expect(probe_post_count == 2, "game must receive exactly one down and one up");
    expect(probe_tap_post_count == 2, "foreground copies must re-enter routing at the current tap, not bypass Wine window hit-testing via PID posting");
    for (unsigned i = 0; i < probe_post_count; i++) {
        CGEventRef delivered = probe_posted_events[i];
        expect(probe_posted_pids[i] == 1234, "both transitions must target the verified game PID");
        expect(CGEventGetLocation(delivered).x == 321.0, "click X must be preserved");
        expect(CGEventGetLocation(delivered).y == base + 37.0, "click Y must be outside the protected 36.5-point strip");
        expect(CGEventGetType(delivered) == (i == 0 ? kCGEventLeftMouseDown : kCGEventLeftMouseUp),
               "down/up event type must be preserved");
        expect(CGEventGetIntegerValueField(delivered, kCGMouseEventClickState) == 2,
               "double-click metadata must be preserved");
        expect(CGEventGetIntegerValueField(delivered, kCGMouseEventNumber) == 88,
               "event number must be preserved");
        expect(CGEventGetFlags(delivered) == kCGEventFlagMaskShift, "modifier flags must be preserved");
        expect(CGEventGetDoubleValueField(delivered, kCGMouseEventPressure) ==
               CGEventGetDoubleValueField(i == 0 ? down : up, kCGMouseEventPressure),
               "encoded button pressure must be preserved");
    }
    expect(CGEventGetLocation(down).y == base + 33.0 && CGEventGetLocation(up).y == base + 33.0,
           "original event coordinates must not be rewritten");
    expect(probe_cursor_operations == 0, "button delivery must not warp, hide, or reassociate the physical cursor");
    CFRelease(down);
    CFRelease(up);
}

static void release_outside_strip_completes_the_same_click(void) {
    clear_posted_events();
    const double base = top_fence_y() - 36.0;
    CGEventRef down = make_button(kCGEventLeftMouseDown, 321.0, base + 33.0, 1);
    CGEventRef up = make_button(kCGEventLeftMouseUp, 400.0, base + 120.0, 1);
    expect(deliver(kCGEventLeftMouseDown, down) == NULL, "protected down must be consumed");
    expect(deliver(kCGEventLeftMouseUp, up) == NULL,
           "release outside the strip must not duplicate the redirected click");
    expect(probe_post_count == 2, "moving out of the strip must still deliver a full game click");
    if (probe_post_count == 2) {
        expect(probe_posted_pids[1] == 1234, "release must use the press destination");
        expect(CGEventGetLocation(probe_posted_events[1]).x == 321.0 &&
               CGEventGetLocation(probe_posted_events[1]).y == base + 37.0,
               "release must use the same safe click anchor as the press");
    }
    expect(CGEventGetLocation(up).x == 400.0 && CGEventGetLocation(up).y == base + 120.0,
           "the original release coordinates must remain untouched");
    expect(probe_cursor_operations == 0, "moving the release must not move the physical cursor");
    CFRelease(down);
    CFRelease(up);
}

static void focus_change_keeps_release_with_the_original_game(void) {
    clear_posted_events();
    const double base = top_fence_y() - 36.0;
    CGEventRef down = make_button(kCGEventLeftMouseDown, 321.0, base + 0.0, 1);
    CGEventRef up = make_button(kCGEventLeftMouseUp, 321.0, base + 0.0, 1);
    deliver(kCGEventLeftMouseDown, down);
    probe_frontmost_pid = 5678;
    atomic_store(&g_capture_target_pid, 5678);
    atomic_store(&g_active, false);
    expect(deliver(kCGEventLeftMouseUp, up) == NULL, "paired release must complete even after focus is lost");
    expect(probe_post_count == 2 && probe_posted_pids[1] == 1234,
           "focus loss must not send the release to a different game");
    expect(probe_tap_post_count == 1, "after focus loss only the down may use global routing; the up must remain PID-targeted");
    probe_frontmost_pid = 1234;
    atomic_store(&g_capture_target_pid, 1234);
    atomic_store(&g_active, true);
    CFRelease(down);
    CFRelease(up);
}

static void tap_disable_releases_a_held_game_button(void) {
    clear_posted_events();
    CGEventRef down = make_button(kCGEventLeftMouseDown, 321.0, top_fence_y(), 1);
    deliver(kCGEventLeftMouseDown, down);
    atomic_store(&g_active, false);
    deliver(kCGEventTapDisabledByUserInput, down);
    expect(probe_post_count == 2, "disabling capture must balance a delivered down with an up");
    if (probe_post_count == 2) {
        expect(probe_posted_pids[1] == 1234 && CGEventGetType(probe_posted_events[1]) == kCGEventLeftMouseUp,
               "cleanup must release the originally targeted game's button");
    }
    expect(probe_cursor_operations == 0, "button cleanup must not manipulate the cursor");
    atomic_store(&g_active, true);
    CGEventRef up = make_button(kCGEventLeftMouseUp, 321.0, top_fence_y(), 1);
    expect(deliver(kCGEventLeftMouseUp, up) == NULL, "the physical release after cleanup must be consumed once");
    expect(probe_post_count == 2, "cleanup must not be followed by a duplicate game release");
    CFRelease(up);
    CFRelease(down);
}

static void buttons_and_motion_keep_their_independent_routes(void) {
    const double base = top_fence_y() - 36.0;
    const double y_values[] = {0.0, 33.0, 36.0, 36.5};
    const CGEventType downs[] = {kCGEventLeftMouseDown, kCGEventRightMouseDown, kCGEventOtherMouseDown};
    const CGEventType ups[] = {kCGEventLeftMouseUp, kCGEventRightMouseUp, kCGEventOtherMouseUp};
    for (size_t i = 0; i < 4; i++) {
        for (size_t button = 0; button < 3; button++) {
            clear_posted_events();
            CGEventRef down = make_button(downs[button], 777.0, base + y_values[i], 1);
            CGEventRef up = make_button(ups[button], 777.0, base + y_values[i], 1);
            expect(deliver(downs[button], down) == NULL && deliver(ups[button], up) == NULL,
                   "every protected button transition must suppress its original");
            expect(probe_post_count == 2, "left/right/middle top clicks must each be delivered once");
            expect(probe_tap_post_count == 2, "each foreground button pair must use downstream tap routing");
            for (unsigned j = 0; j < probe_post_count; j++) {
                expect(CGEventGetLocation(probe_posted_events[j]).x == 777.0 &&
                       CGEventGetLocation(probe_posted_events[j]).y == base + 37.0,
                       "the whole protected strip must map to the same safe row");
                expect(CGEventGetIntegerValueField(probe_posted_events[j], kCGMouseEventButtonNumber) == (int64_t)button,
                       "the original mouse button identity must be preserved");
                expect(deliver(CGEventGetType(probe_posted_events[j]), probe_posted_events[j]) == probe_posted_events[j],
                       "a routed copy must pass a repeated tap visit unchanged");
            }
            expect(probe_post_count == 2, "routed copies must never recurse or duplicate the click");
            CFRelease(down);
            CFRelease(up);
        }
    }
    const CGEventType motions[] = {kCGEventMouseMoved, kCGEventLeftMouseDragged,
                                  kCGEventRightMouseDragged, kCGEventOtherMouseDragged};
    clear_posted_events();
    for (size_t i = 0; i < 4; i++) {
        CGEventRef event = CGEventCreateMouseEvent(NULL, motions[i], CGPointMake(777.0, base), kCGMouseButtonLeft);
        CGEventSetIntegerValueField(event, kCGMouseEventDeltaX, 0);
        CGEventSetIntegerValueField(event, kCGMouseEventDeltaY, -7);
        CFDataRef before = CGEventCreateData(NULL, event);
        expect(deliver(motions[i], event) == event, "movement and drag events must use the original route");
        CFDataRef after = CGEventCreateData(NULL, event);
        expect(CFEqual(before, after), "every serialized physical motion field must remain unchanged");
        CFRelease(before);
        CFRelease(after);
        CFRelease(event);
    }
    expect(probe_post_count == 0 && probe_cursor_operations == 0,
           "camera motion must never be copied, PID-posted, warped, or reassociated");
}

static void ordinary_and_inactive_clicks_are_unchanged(void) {
    clear_posted_events();
    const double base = top_fence_y() - 36.0;
    for (unsigned active = 0; active < 2; active++) {
        atomic_store(&g_active, active != 0);
        const double y_values[] = {37.0, 100.0, 0.0};
        for (size_t i = 0; i < (active ? 2u : 3u); i++) {
            CGEventRef down = make_button(kCGEventLeftMouseDown, 333.0, base + y_values[i], 1);
            CGEventRef up = make_button(kCGEventLeftMouseUp, 333.0, base + y_values[i], 1);
            expect(deliver(kCGEventLeftMouseDown, down) == down && deliver(kCGEventLeftMouseUp, up) == up,
                   "ordinary or inactive clicks must pass the original event once");
            expect(CGEventGetLocation(down).y == base + y_values[i], "ordinary click coordinates must be unchanged");
            CFRelease(down);
            CFRelease(up);
        }
    }
    expect(probe_post_count == 0 && probe_cursor_operations == 0, "ordinary clicks must not create extra events");
    atomic_store(&g_active, true);
}

static void stale_focus_cannot_swallow_desktop_clicks(void) {
    clear_posted_events();
    probe_frontmost_pid = 5678;
    CGEventRef down = make_button(kCGEventLeftMouseDown, 321.0, top_fence_y(), 1);
    expect(deliver(kCGEventLeftMouseDown, down) == down,
           "a stale activation sample must not suppress a different app's click");
    expect(probe_post_count == 0, "a top click must not be posted to a game that is no longer frontmost");
    probe_frontmost_pid = 1234;
    CFRelease(down);
}

static void activation_park_must_not_suppress_a_real_button(void) {
    clear_posted_events();
    CGPoint point = CGPointMake(321.0, top_fence_y() + 300.0);
    g_last_capture_park = monotonic_seconds();
    g_last_capture_park_target = point;
    g_pending_capture_park_suppression = true;
    CGEventRef down = make_button(kCGEventLeftMouseDown, point.x, point.y, 1);
    CGEventSetIntegerValueField(down, kCGMouseEventDeltaX, 100);
    expect(deliver(kCGEventLeftMouseDown, down) == down, "activation park suppression must apply only to motion");
    expect(probe_post_count == 0, "ordinary post-activation clicks must not be rerouted");
    g_pending_capture_park_suppression = false;
    g_last_capture_park = 0.0;
    CFRelease(down);
}

int main(void) {
    g_config.mode = MODE_CAPTURE;
    g_config.fence_y = 36.0;
    atomic_store(&g_active, true);
    atomic_store(&g_capture_target_pid, 1234);
    g_cursor_visibility_lookup_finished = true;
    g_cursor_is_visible = probe_cursor_is_visible;
    top_click_reaches_game_once();
    release_outside_strip_completes_the_same_click();
    focus_change_keeps_release_with_the_original_game();
    tap_disable_releases_a_held_game_button();
    buttons_and_motion_keep_their_independent_routes();
    ordinary_and_inactive_clicks_are_unchanged();
    stale_focus_cannot_swallow_desktop_clicks();
    activation_park_must_not_suppress_a_real_button();
    clear_posted_events();
    if (failures) return 1;
    puts("PASS: protected click reaches the game once at safe coordinates without cursor operations.");
    return 0;
}

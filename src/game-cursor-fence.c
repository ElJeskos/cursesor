#define _DARWIN_C_SOURCE

#include <ApplicationServices/ApplicationServices.h>
#include <CoreFoundation/CoreFoundation.h>
#include <ctype.h>
#include <dlfcn.h>
#include <fcntl.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/file.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "frontmost_app.h"
#include "capture_edge_policy.h"
#include "capture_watchdog_policy.h"

#define MAX_NEEDLES 32
#define LINE_SIZE 32768
#define CAPTURE_BUTTON_TAG INT64_C(0x474346434c49434b)
#define MAX_CAPTURE_BUTTONS 32

typedef enum {
    MODE_CAPTURE = 0,
    MODE_RECENTER = 1,
    MODE_CLAMP = 2,
} CursorMode;

typedef struct {
    const char *needles[MAX_NEEDLES];
    int needle_count;
    bool process_gate;
    bool provider_games;
    bool polling_fallback;
    bool frontmost_gate;
    bool verbose;
    double fence_y;
    double hz;
    double idle_hz;
    double process_poll_seconds;
    const char *log_file;
    const char *debug_log_file;
    CursorMode mode;
} Config;

typedef struct {
    bool initialized;
    CGPoint last_physical;
} PointerState;

static Config g_config = {
    .process_gate = true,
    .provider_games = true,
    .polling_fallback = true,
    .frontmost_gate = true,
    .verbose = false,
    .fence_y = 36.0,
    .hz = 120.0,
    .idle_hz = 2.0,
    .process_poll_seconds = 1.0,
    .mode = MODE_CAPTURE,
};

static _Atomic bool g_keep_running = true;
static _Atomic bool g_active = false;
static _Atomic bool g_cursor_detached = false;
static _Atomic unsigned long g_clamp_count = 0;
static _Atomic unsigned long g_recenter_count = 0;
static _Atomic unsigned long g_capture_recovery_count = 0;
static _Atomic unsigned long g_cursor_rehide_count = 0;
static _Atomic unsigned long g_capture_forward_count = 0;
static _Atomic pid_t g_capture_target_pid = 0;
static pthread_mutex_t g_activation_mutex = PTHREAD_MUTEX_INITIALIZER;
static CFMachPortRef g_event_tap = NULL;
static CFRunLoopSourceRef g_event_tap_source = NULL;
static bool g_event_tap_enabled = false;
static bool g_cursor_hidden = false;
static PointerState g_pointer_state = {0};
static FILE *g_debug_log = NULL;
static bool g_dry_run = false;
static bool g_check_running = false;
static bool g_check_frontmost = false;
static pid_t g_check_pid = 0;
static int g_singleton_lock_fd = -1;
static double g_last_motion_debug = 0.0;
static double g_last_capture_park = 0.0;
static CGPoint g_last_capture_park_target = {0};
static bool g_pending_capture_park_suppression = false;
static GCFCaptureWatchdogState g_capture_watchdog_state = {0};

typedef struct {
    pid_t target_pid;
    CGPoint location;
    CGEventRef down_event;
    bool cleanup_release_pending;
} CapturedButton;

static CapturedButton g_captured_buttons[MAX_CAPTURE_BUTTONS] = {0};

typedef bool (*CursorIsVisibleFunction)(void);
static CursorIsVisibleFunction g_cursor_is_visible = NULL;
static bool g_cursor_visibility_lookup_finished = false;

static const char *mode_name(CursorMode mode);
static void release_captured_buttons(void);

static void handle_signal(int signum) {
    (void)signum;
    atomic_store(&g_keep_running, false);
}

static int acquire_singleton_lock(void) {
    const char *temp_directory = getenv("TMPDIR");
    if (!temp_directory || temp_directory[0] != '/') {
        temp_directory = "/tmp";
    }

    char lock_path[PATH_MAX];
    const char *separator = temp_directory[strlen(temp_directory) - 1] == '/' ? "" : "/";
    int path_length = snprintf(lock_path,
                               sizeof(lock_path),
                               "%s%sgame-cursor-fence-%u.lock",
                               temp_directory,
                               separator,
                               (unsigned)getuid());
    if (path_length < 0 || (size_t)path_length >= sizeof(lock_path)) {
        fprintf(stderr, "[game-cursor-fence] singleton lock path is too long\n");
        return -1;
    }

    int lock_fd = open(lock_path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (lock_fd < 0) {
        fprintf(stderr, "[game-cursor-fence] failed to open singleton lock: %s\n", lock_path);
        return -1;
    }
    if (flock(lock_fd, LOCK_EX | LOCK_NB) != 0) {
        close(lock_fd);
        return 0;
    }

    g_singleton_lock_fd = lock_fd;
    if (ftruncate(lock_fd, 0) == 0) {
        dprintf(lock_fd, "%d\n", getpid());
    }
    return 1;
}

static double monotonic_seconds(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec / 1000000000.0;
}

static void debug_log(const char *format, ...) {
    if (!g_debug_log) {
        return;
    }

    fprintf(g_debug_log, "[DEBUG-gcf] t=%.3f ", monotonic_seconds());
    va_list args;
    va_start(args, format);
    vfprintf(g_debug_log, format, args);
    va_end(args);
    fputc('\n', g_debug_log);
}

static bool parse_positive_double(const char *text, double *out) {
    char *end = NULL;
    double value = strtod(text, &end);
    if (end == text || *end != '\0' || value <= 0.0 || !isfinite(value)) {
        return false;
    }
    *out = value;
    return true;
}

static bool contains_case_insensitive(const char *haystack, const char *needle) {
    if (needle[0] == '\0') {
        return true;
    }
    size_t needle_len = strlen(needle);
    for (const char *p = haystack; *p; p++) {
        if (strncasecmp(p, needle, needle_len) == 0) {
            return true;
        }
    }
    return false;
}

static bool line_is_scan_noise(const char *line) {
    static const char *noise[] = {
        "game-cursor-fence",
        "/bin/ps -ax",
        "/bin/ps eww",
        " rg ",
        " grep ",
        " awk ",
        "pgrep",
        "gamehub_cli.py",
    };
    for (size_t i = 0; i < sizeof(noise) / sizeof(noise[0]); i++) {
        if (contains_case_insensitive(line, noise[i])) {
            return true;
        }
    }
    return false;
}

static bool line_has_provider_runtime_marker(const char *line) {
    static const char *markers[] = {
        "WINEPREFIX=/Users/",
        "/Library/Application Support/com.gamemac.www/wine-engine/containers/",
        "/Library/Application Support/CrossOver/Bottles/",
        "PROCESS_TAG=wine_engine_container:",
        "WINEENGINE_MONITOR_LAUNCH_TARGET=",
        "DYLD_INSERT_LIBRARIES=/Applications/GameHub.app/",
        "/Applications/CrossOver.app/",
    };
    for (size_t i = 0; i < sizeof(markers) / sizeof(markers[0]); i++) {
        if (contains_case_insensitive(line, markers[i])) {
            return true;
        }
    }
    return false;
}

static bool line_has_common_game_path(const char *line) {
    static const char *paths[] = {
        "C:\\GOG Games\\",
        "\\steamapps\\common\\",
        "drive_c/GOG Games/",
        "/steamapps/common/",
        "C:\\Program Files\\",
        "C:\\Program Files (x86)\\",
        "/drive_c/Program Files/",
        "/drive_c/Program Files (x86)/",
    };
    for (size_t i = 0; i < sizeof(paths) / sizeof(paths[0]); i++) {
        if (contains_case_insensitive(line, paths[i])) {
            return true;
        }
    }
    return false;
}

static bool line_is_provider_service_or_installer(const char *line) {
    static const char *blocked[] = {
        "Setup.exe",
        "Installer.exe",
        "Uninstall.exe",
        "/setup",
        "/installer",
        "/unins",
        "C:\\windows\\",
        "\\winedevice.exe",
        "\\wineserver",
        "/wineserver",
        " wineserver ",
        "\\wineboot.exe",
        "\\conhost.exe",
        "\\services.exe",
        "\\explorer.exe",
        "\\plugplay.exe",
        "\\svchost.exe",
        "\\rpcss.exe",
        "\\tabtip.exe",
        "\\rundll.exe",
        "\\rundll32.exe",
        "\\regedit.exe",
        "\\notepad.exe",
        "\\winhelp.exe",
        "\\winhlp32.exe",
        "\\hh.exe",
        "\\steam.exe",
        "steamservice.exe",
        "steamwebhelper.exe",
        "gameoverlayui.exe",
        "gameoverlayui64.exe",
        "UnityCrashHandler",
        "CrashHandler",
        "crashpad_handler",
        "\\dxsetup.exe",
        "\\vcredist",
        "\\vc_redist",
        "\\dotnet",
        "\\uninstall",
        "friends list",
        "downloads",
        "settings",
        "wine configuration",
        "wine explorer",
        "program error",
        "fatal error",
        "crash",
        "installer",
        "setup",
        "uninstall",
    };
    for (size_t i = 0; i < sizeof(blocked) / sizeof(blocked[0]); i++) {
        if (contains_case_insensitive(line, blocked[i])) {
            return true;
        }
    }
    return false;
}

static bool command_looks_like_provider_game(const char *command) {
    if (line_is_provider_service_or_installer(command)) {
        return false;
    }
    if (line_has_common_game_path(command)) {
        return true;
    }
    if (contains_case_insensitive(command, ".exe") &&
        !contains_case_insensitive(command, "Setup.exe") &&
        !contains_case_insensitive(command, "Installer.exe") &&
        !contains_case_insensitive(command, "Uninstall.exe")) {
        return true;
    }
    return contains_case_insensitive(command, "wine") ||
           contains_case_insensitive(command, "wineloader");
}

static bool command_matches_explicit_needles(const char *command) {
    for (int i = 0; i < g_config.needle_count; i++) {
        if (contains_case_insensitive(command, g_config.needles[i])) {
            return true;
        }
    }
    return false;
}

static bool read_process_command(pid_t pid, char *buffer, size_t buffer_size) {
    char command[128];
    snprintf(command, sizeof(command), "/bin/ps -p %d -o args=", pid);
    FILE *ps = popen(command, "r");
    if (!ps) {
        return false;
    }
    bool ok = fgets(buffer, buffer_size, ps) != NULL;
    pclose(ps);
    return ok;
}

static bool parse_process_list_line(char *line, pid_t *pid, char **command) {
    char *cursor = line;
    while (isspace((unsigned char)*cursor)) {
        cursor++;
    }

    char *pid_end = NULL;
    long parsed_pid = strtol(cursor, &pid_end, 10);
    if (pid_end == cursor || parsed_pid <= 0 || parsed_pid > INT_MAX) {
        return false;
    }
    while (isspace((unsigned char)*pid_end)) {
        pid_end++;
    }
    if (*pid_end == '\0') {
        return false;
    }

    *pid = (pid_t)parsed_pid;
    if (command) {
        *command = pid_end;
    }
    return true;
}

static bool provider_runtime_is_running(void) {
    FILE *ps = popen("/bin/ps eww -ax -o pid=,args=", "r");
    if (!ps) {
        return false;
    }

    char line[LINE_SIZE];
    bool matched = false;
    while (fgets(line, sizeof(line), ps)) {
        if (!line_has_provider_runtime_marker(line)) {
            continue;
        }

        pid_t pid = 0;
        char command[LINE_SIZE];
        if (!parse_process_list_line(line, &pid, NULL) ||
            !read_process_command(pid, command, sizeof(command))) {
            continue;
        }
        if (!line_is_scan_noise(command)) {
            matched = true;
            break;
        }
    }
    pclose(ps);
    return matched;
}

static bool process_matches_config(const char *command, bool provider_runtime_present) {
    if (line_is_scan_noise(command)) {
        return false;
    }
    if (command_matches_explicit_needles(command)) {
        return true;
    }
    if (!g_config.provider_games || !provider_runtime_present) {
        return false;
    }
    return command_looks_like_provider_game(command);
}

static bool application_pid_matches_config(pid_t application_pid) {
    if (application_pid <= 0) {
        return false;
    }

    char command[LINE_SIZE];
    if (!read_process_command(application_pid, command, sizeof(command))) {
        return false;
    }
    return process_matches_config(command, provider_runtime_is_running());
}

static pid_t matching_frontmost_application_pid(void) {
    pid_t application_pid = gcf_frontmost_application_pid();
    return application_pid_matches_config(application_pid) ? application_pid : 0;
}

static bool any_matching_process(void) {
    if (!g_config.process_gate) {
        return true;
    }

    bool provider_runtime_present = provider_runtime_is_running();
    FILE *ps = popen("/bin/ps -ax -o pid=,args=", "r");
    if (!ps) {
        return false;
    }

    char line[LINE_SIZE];
    bool matched = false;
    while (fgets(line, sizeof(line), ps)) {
        pid_t pid = 0;
        char *command = NULL;
        if (!parse_process_list_line(line, &pid, &command)) {
            continue;
        }
        if (process_matches_config(command, provider_runtime_present)) {
            matched = true;
            break;
        }
    }
    pclose(ps);
    return matched;
}

static bool should_activate(void) {
    if (!any_matching_process()) {
        atomic_store(&g_capture_target_pid, 0);
        return false;
    }
    if (g_config.mode == MODE_CAPTURE) {
        pid_t target_pid = matching_frontmost_application_pid();
        atomic_store(&g_capture_target_pid, target_pid);
        if (g_config.frontmost_gate) {
            return target_pid > 0;
        }
    } else {
        atomic_store(&g_capture_target_pid, 0);
    }
    return true;
}

static bool get_desktop_bounds(CGRect *out) {
    uint32_t count = 0;
    if (CGGetActiveDisplayList(0, NULL, &count) != kCGErrorSuccess || count == 0) {
        return false;
    }

    CGDirectDisplayID displays[32];
    if (count > 32) {
        count = 32;
    }
    if (CGGetActiveDisplayList(count, displays, &count) != kCGErrorSuccess || count == 0) {
        return false;
    }

    CGRect bounds = CGDisplayBounds(displays[0]);
    for (uint32_t i = 1; i < count; i++) {
        bounds = CGRectUnion(bounds, CGDisplayBounds(displays[i]));
    }
    *out = bounds;
    return true;
}

static CGPoint desktop_center(void) {
    CGRect bounds;
    if (!get_desktop_bounds(&bounds)) {
        bounds = CGDisplayBounds(CGMainDisplayID());
    }
    return CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
}

static bool should_recenter(CGPoint location) {
    CGRect bounds;
    if (!get_desktop_bounds(&bounds)) {
        bounds = CGDisplayBounds(CGMainDisplayID());
    }

    const double margin = 96.0;
    const double top = CGRectGetMinY(bounds) + g_config.fence_y;
    const double bottom = CGRectGetMaxY(bounds);
    const double left = CGRectGetMinX(bounds);
    const double right = CGRectGetMaxX(bounds);

    return location.y < top + margin ||
           location.y > bottom - margin ||
           location.x < left + margin ||
           location.x > right - margin;
}

static double top_fence_y(void) {
    CGRect bounds;
    if (!get_desktop_bounds(&bounds)) {
        bounds = CGDisplayBounds(CGMainDisplayID());
    }
    return CGRectGetMinY(bounds) + g_config.fence_y;
}

static CGPoint capture_safe_park_point(void) {
    CGRect bounds;
    if (!get_desktop_bounds(&bounds)) {
        bounds = CGDisplayBounds(CGMainDisplayID());
    }

    double y = CGRectGetMinY(bounds) + CGRectGetHeight(bounds) * 0.65;
    double minimum_y = top_fence_y() + 240.0;
    if (y < minimum_y) {
        y = minimum_y;
    }
    if (y > CGRectGetMaxY(bounds) - 240.0) {
        y = CGRectGetMidY(bounds);
    }

    return CGPointMake(CGRectGetMidX(bounds), y);
}

static double capture_top_guard_y(void) {
    return top_fence_y() + 48.0;
}

static bool clamp_event_to_top_fence(CGEventRef event, CGPoint *location) {
    double top = top_fence_y();
    if (location->y >= top) {
        return false;
    }
    location->y = top;
    CGEventSetLocation(event, *location);
    atomic_fetch_add(&g_clamp_count, 1);
    return true;
}

static void warp_cursor_to_top_fence_if_needed(CGPoint location) {
    double top = top_fence_y();
    if (location.y >= top) {
        return;
    }
    debug_log("top-fence-warp old=(%.1f,%.1f) new=(%.1f,%.1f) top=%.1f active=%s detached=%s",
              location.x,
              location.y,
              location.x,
              top,
              top,
              atomic_load(&g_active) ? "true" : "false",
              atomic_load(&g_cursor_detached) ? "true" : "false");
    location.y = top;
    CGWarpMouseCursorPosition(location);
    g_pointer_state.last_physical = location;
    atomic_fetch_add(&g_clamp_count, 1);
}

static void park_capture_cursor_once(void) {
    CGPoint target = capture_safe_park_point();
    g_last_capture_park = monotonic_seconds();
    g_last_capture_park_target = target;
    g_pending_capture_park_suppression = true;
    debug_log("capture-safe-park new=(%.1f,%.1f) active=%s detached=%s",
              target.x,
              target.y,
              atomic_load(&g_active) ? "true" : "false",
              atomic_load(&g_cursor_detached) ? "true" : "false");
    CGWarpMouseCursorPosition(target);
    g_pointer_state.last_physical = target;
    atomic_fetch_add(&g_recenter_count, 1);
}

static bool should_suppress_capture_park_event(CGPoint location, int64_t delta_x, int64_t delta_y, double now) {
    if (g_config.mode != MODE_CAPTURE || g_last_capture_park <= 0.0 || !g_pending_capture_park_suppression) {
        return false;
    }

    double age = now - g_last_capture_park;
    if (age < 0.0 || age > 15.0) {
        g_pending_capture_park_suppression = false;
        return false;
    }

    if (fabs(location.y - g_last_capture_park_target.y) <= 24.0 &&
        fabs(location.x - g_last_capture_park_target.x) <= 24.0 &&
        (llabs(delta_x) > 40 || llabs(delta_y) > 40)) {
        g_pending_capture_park_suppression = false;
        return true;
    }

    if (fabs(location.y - g_last_capture_park_target.y) > 160.0 ||
        fabs(location.x - g_last_capture_park_target.x) > 160.0) {
        g_pending_capture_park_suppression = false;
    }

    if (age > 0.35) {
        g_pending_capture_park_suppression = false;
    }

    return false;
}

static void recenter_cursor_if_needed(CGPoint location) {
    if (!should_recenter(location)) {
        return;
    }
    CGPoint center = desktop_center();
    debug_log("recenter-warp old=(%.1f,%.1f) new=(%.1f,%.1f) mode=%s",
              location.x,
              location.y,
              center.x,
              center.y,
              mode_name(g_config.mode));
    CGWarpMouseCursorPosition(center);
    g_pointer_state.last_physical = center;
    atomic_fetch_add(&g_recenter_count, 1);
}

static void set_event_tap_enabled(bool enabled) {
    if (!enabled) {
        release_captured_buttons();
    }
    if (!g_event_tap || g_event_tap_enabled == enabled) {
        return;
    }
    CGEventTapEnable(g_event_tap, enabled);
    g_event_tap_enabled = enabled;
    g_pointer_state.initialized = false;
    debug_log("event-tap-enabled enabled=%s mode=%s", enabled ? "true" : "false", mode_name(g_config.mode));
}

static void set_cursor_hidden(bool hidden) {
    if (g_cursor_hidden == hidden) {
        return;
    }

    CGError error = hidden ? CGDisplayHideCursor(CGMainDisplayID()) : CGDisplayShowCursor(CGMainDisplayID());
    if (error == kCGErrorSuccess) {
        g_cursor_hidden = hidden;
        debug_log("cursor-hidden hidden=%s", hidden ? "true" : "false");
    } else {
        debug_log("cursor-hidden-error hidden=%s error=%d", hidden ? "true" : "false", error);
    }
}

static void set_cursor_detached(bool detached) {
    bool was_detached = atomic_load(&g_cursor_detached);
    if (was_detached == detached) {
        return;
    }
    CGError error = CGAssociateMouseAndMouseCursorPosition(detached ? false : true);
    if (error == kCGErrorSuccess) {
        atomic_store(&g_cursor_detached, detached);
        if (!detached) {
            g_capture_watchdog_state = (GCFCaptureWatchdogState){0};
        }
        debug_log("cursor-association detached=%s", detached ? "true" : "false");
    } else {
        fprintf(stderr, "[game-cursor-fence] CGAssociateMouseAndMouseCursorPosition failed: %d\n", error);
        debug_log("cursor-association-error detached=%s error=%d", detached ? "true" : "false", error);
    }
}

static bool system_cursor_is_visible(void) {
    if (!g_cursor_visibility_lookup_finished) {
        g_cursor_is_visible = (CursorIsVisibleFunction)dlsym(RTLD_DEFAULT, "CGCursorIsVisible");
        g_cursor_visibility_lookup_finished = true;
        debug_log("cursor-visibility-api available=%s", g_cursor_is_visible ? "true" : "false");
    }
    return g_cursor_is_visible && g_cursor_is_visible();
}

static void rehide_visible_cursor(void) {
    CGError error = CGDisplayHideCursor(CGMainDisplayID());
    if (error == kCGErrorSuccess) {
        g_cursor_hidden = true;
        atomic_fetch_add(&g_cursor_rehide_count, 1);
        debug_log("capture-watchdog-rehide count=%lu", atomic_load(&g_cursor_rehide_count));
    } else {
        debug_log("capture-watchdog-rehide-error error=%d", error);
    }
}

__attribute__((noinline))
static void capture_watchdog_tick(CGPoint location) {
    (void)location;
    if (g_config.mode != MODE_CAPTURE || !atomic_load(&g_active)) {
        return;
    }

    GCFCaptureWatchdogDecision decision = gcf_capture_watchdog_update(
        &g_capture_watchdog_state,
        system_cursor_is_visible(),
        monotonic_seconds()
    );
    if (decision.should_rehide) {
        rehide_visible_cursor();
    }
    if (!decision.should_reassociate) {
        return;
    }

    CGError error = CGAssociateMouseAndMouseCursorPosition(false);
    if (error == kCGErrorSuccess) {
        atomic_store(&g_cursor_detached, true);
        atomic_fetch_add(&g_capture_recovery_count, 1);
        debug_log("capture-watchdog-reassociate visibilityBreach=true count=%lu",
                  atomic_load(&g_capture_recovery_count));
    } else {
        debug_log("capture-watchdog-reassociate-error error=%d", error);
    }
}

static bool is_capture_button_release(CGEventType type) {
    return type == kCGEventLeftMouseUp || type == kCGEventRightMouseUp || type == kCGEventOtherMouseUp;
}

static CapturedButton *capture_button_state(CGEventType type, CGEventRef event) {
    int64_t button;
    if (type == kCGEventLeftMouseDown || type == kCGEventLeftMouseUp) {
        button = 0;
    } else if (type == kCGEventRightMouseDown || type == kCGEventRightMouseUp) {
        button = 1;
    } else if (type == kCGEventOtherMouseDown || type == kCGEventOtherMouseUp) {
        button = CGEventGetIntegerValueField(event, kCGMouseEventButtonNumber);
    } else {
        return NULL;
    }
    return button >= 0 && button < MAX_CAPTURE_BUTTONS ? &g_captured_buttons[button] : NULL;
}

static void release_captured_button(CapturedButton *state) {
    if (!state->down_event) {
        return;
    }
    CGEventType down_type = CGEventGetType(state->down_event);
    CGEventType up_type = down_type == kCGEventLeftMouseDown ? kCGEventLeftMouseUp :
        (down_type == kCGEventRightMouseDown ? kCGEventRightMouseUp : kCGEventOtherMouseUp);
    /* Reuse the retained button copy so cleanup cannot fail on allocation. */
    CGEventSetType(state->down_event, up_type);
    CGEventSetDoubleValueField(state->down_event, kCGMouseEventPressure, 0.0);
    CGEventSetTimestamp(state->down_event, (CGEventTimestamp)(monotonic_seconds() * 1000000000.0));
    CGEventPostToPid(state->target_pid, state->down_event);
    atomic_fetch_add(&g_capture_forward_count, 1);
    debug_log("capture-top-click-cleanup-up targetPid=%d type=%u", state->target_pid, (unsigned)up_type);
    CFRelease(state->down_event);
    *state = (CapturedButton){.target_pid = state->target_pid, .cleanup_release_pending = true};
}

static void release_captured_buttons(void) {
    for (size_t i = 0; i < MAX_CAPTURE_BUTTONS; i++) {
        release_captured_button(&g_captured_buttons[i]);
    }
}

/* Safe foreground copies must continue through WindowServer hit-testing.
 * PID-only posting bypasses that route and Wine can ignore the click when
 * its window has not captured the mouse. Tap posting does not warp the cursor.
 * Original motion remains untouched. */
static bool forward_capture_button_to_game(CGEventTapProxy proxy, CGEventRef event, CGEventType type, CGPoint location) {
    CapturedButton *state = capture_button_state(type, event);
    bool paired_release = is_capture_button_release(type) && state && state->down_event;
    pid_t target_pid;
    CGPoint safe_location;
    if (paired_release) {
        target_pid = state->target_pid;
        safe_location = state->location;
    } else {
        target_pid = atomic_load(&g_capture_target_pid);
        pid_t frontmost_pid = gcf_frontmost_application_pid();
        if (target_pid <= 0 && !g_config.frontmost_gate) {
            target_pid = frontmost_pid;
        }
        if (target_pid <= 0 || target_pid != frontmost_pid) {
            debug_log("capture-top-click-no-target type=%u", (unsigned)type);
            return false;
        }
        safe_location = CGPointMake(location.x, top_fence_y() + 1.0);
    }

    CGEventRef copy = CGEventCreateCopy(event);
    if (!copy) {
        return false;
    }
    CGEventSetLocation(copy, safe_location);
    CGEventSetIntegerValueField(copy, kCGEventSourceUserData, CAPTURE_BUTTON_TAG);
    if (state && state->down_event && !paired_release) {
        release_captured_button(state);
    }
    bool use_tap_route = proxy && target_pid == gcf_frontmost_application_pid();
    if (use_tap_route) {
        CGEventTapPostEvent(proxy, copy);
    } else {
        /* Never route a paired release into an unrelated foreground app.
         * Background release remains best-effort PID delivery. */
        CGEventPostToPid(target_pid, copy);
    }
    if (state) {
        if (state->down_event) {
            CFRelease(state->down_event);
        }
        *state = (CapturedButton){0};
        if (!is_capture_button_release(type)) {
            *state = (CapturedButton){.target_pid = target_pid, .location = safe_location,
                                      .down_event = (CGEventRef)CFRetain(copy)};
        }
    }
    CFRelease(copy);
    atomic_fetch_add(&g_capture_forward_count, 1);
    debug_log("capture-top-click-forwarded targetPid=%d old=(%.1f,%.1f) new=(%.1f,%.1f) type=%u route=%s",
              target_pid, location.x, location.y, safe_location.x, safe_location.y, (unsigned)type,
              use_tap_route ? "tap" : "pid-release");
    return true;
}

static CGEventRef cursor_event_callback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *user_info) {
    (void)user_info;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        release_captured_buttons();
        if (g_event_tap && atomic_load(&g_active)) {
            CGEventTapEnable(g_event_tap, true);
            g_event_tap_enabled = true;
            puts("[game-cursor-fence] event tap re-enabled");
            debug_log("event-tap-reenabled type=%u", (unsigned)type);
        } else {
            g_event_tap_enabled = false;
            debug_log("event-tap-disabled type=%u active=%s", (unsigned)type, atomic_load(&g_active) ? "true" : "false");
        }
        return event;
    }

    if (event && CGEventGetIntegerValueField(event, kCGEventSourceUserData) == CAPTURE_BUTTON_TAG) {
        return event;
    }
    if (event) {
        CapturedButton *state = capture_button_state(type, event);
        if (state && is_capture_button_release(type)) {
            if (state->cleanup_release_pending) {
                pid_t released_pid = state->target_pid;
                *state = (CapturedButton){0};
                if (atomic_load(&g_active) && released_pid == gcf_frontmost_application_pid()) {
                    return NULL;
                }
            } else if (state->down_event) {
                if (atomic_load(&g_active) && system_cursor_is_visible()) {
                    rehide_visible_cursor();
                }
                forward_capture_button_to_game(proxy, event, type, CGEventGetLocation(event));
                return NULL;
            }
        } else if (state) {
            state->cleanup_release_pending = false;
        }
    }
    if (!atomic_load(&g_active) || !event) {
        g_pointer_state.initialized = false;
        return event;
    }

    bool is_mouse_motion = type == kCGEventMouseMoved ||
                           type == kCGEventLeftMouseDragged ||
                           type == kCGEventRightMouseDragged ||
                           type == kCGEventOtherMouseDragged;
    bool is_mouse_button = type == kCGEventLeftMouseDown ||
                           type == kCGEventLeftMouseUp ||
                           type == kCGEventRightMouseDown ||
                           type == kCGEventRightMouseUp ||
                           type == kCGEventOtherMouseDown ||
                           type == kCGEventOtherMouseUp;
    if (!is_mouse_motion && !is_mouse_button) {
        return event;
    }

    CGPoint location = CGEventGetLocation(event);
    if (!g_pointer_state.initialized) {
        g_pointer_state.last_physical = location;
        g_pointer_state.initialized = true;
    }

    if (g_config.mode == MODE_CAPTURE) {
        /*
         * The incoming HID location may remain at y=0 while the protected
         * WindowServer cursor is fenced at y=36. Feeding both coordinates
         * into the watchdog makes its anchor oscillate and repeatedly calls
         * CGAssociateMouseAndMouseCursorPosition(false) on the input path.
         * The main loop samples the actual WindowServer location instead.
         */
        if (is_mouse_button) {
            pid_t target_pid = atomic_load(&g_capture_target_pid);
            if (g_config.frontmost_gate &&
                (target_pid <= 0 || target_pid != gcf_frontmost_application_pid())) {
                return event;
            }
            if (system_cursor_is_visible()) {
                rehide_visible_cursor();
            }
        }
        double now = monotonic_seconds();
        double top = top_fence_y();
        int64_t delta_x = CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
        int64_t delta_y = CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
        double guard = capture_top_guard_y();
        double protected_button_top = top_fence_y() + 0.5;
        if (is_mouse_button &&
            gcf_capture_edge_should_suppress_button(location.y, protected_button_top)) {
            forward_capture_button_to_game(proxy, event, type, location);
            /* Delete the unsafe original; the game receives just the safe copy. */
            return NULL;
        }
        if (location.y <= guard) {
            if (is_mouse_motion && now - g_last_motion_debug >= 0.05) {
                debug_log("capture-top-motion-observed loc=(%.1f,%.1f) delta=(%lld,%lld) type=%u guard=%.1f",
                          location.x,
                          location.y,
                          (long long)delta_x,
                          (long long)delta_y,
                          (unsigned)type,
                          guard);
                g_last_motion_debug = now;
            }
        }
        if (is_mouse_motion && should_suppress_capture_park_event(location, delta_x, delta_y, now)) {
            debug_log("suppress-park-event loc=(%.1f,%.1f) delta=(%lld,%lld) age=%.3f",
                      location.x,
                      location.y,
                      (long long)delta_x,
                      (long long)delta_y,
                      now - g_last_capture_park);
            return NULL;
        }
        if ((location.y <= top + 64.0 || delta_y != 0) && now - g_last_motion_debug >= 0.05) {
            debug_log("motion-event loc=(%.1f,%.1f) delta=(%lld,%lld) top=%.1f detached=%s tapEnabled=%s",
                      location.x,
                      location.y,
                      (long long)delta_x,
                      (long long)delta_y,
                      top,
                      atomic_load(&g_cursor_detached) ? "true" : "false",
                      g_event_tap_enabled ? "true" : "false");
            g_last_motion_debug = now;
        }
    }

    if (g_config.mode == MODE_CAPTURE) {
        /* Capture mode leaves all physical motion fields untouched. */
    } else if (g_config.mode == MODE_CLAMP) {
        clamp_event_to_top_fence(event, &location);
    } else if (g_config.mode == MODE_RECENTER) {
        clamp_event_to_top_fence(event, &location);
        recenter_cursor_if_needed(location);
    }

    g_pointer_state.last_physical = location;
    return event;
}

static bool install_event_tap(const char **mode_name) {
    if (g_event_tap) {
        return true;
    }

    CGEventMask mask =
        CGEventMaskBit(kCGEventMouseMoved) |
        CGEventMaskBit(kCGEventLeftMouseDragged) |
        CGEventMaskBit(kCGEventRightMouseDragged) |
        CGEventMaskBit(kCGEventOtherMouseDragged) |
        CGEventMaskBit(kCGEventLeftMouseDown) |
        CGEventMaskBit(kCGEventLeftMouseUp) |
        CGEventMaskBit(kCGEventRightMouseDown) |
        CGEventMaskBit(kCGEventRightMouseUp) |
        CGEventMaskBit(kCGEventOtherMouseDown) |
        CGEventMaskBit(kCGEventOtherMouseUp);

    CGEventTapOptions options = kCGEventTapOptionDefault;

    g_event_tap = CGEventTapCreate(kCGHIDEventTap,
                                   kCGHeadInsertEventTap,
                                   options,
                                   mask,
                                   cursor_event_callback,
                                   NULL);
    if (g_event_tap) {
        *mode_name = g_config.mode == MODE_CAPTURE ? "capture-filter" : (g_config.mode == MODE_RECENTER ? "recenter-hid" : "clamp-hid");
    } else {
        g_event_tap = CGEventTapCreate(kCGSessionEventTap,
                                       kCGHeadInsertEventTap,
                                       options,
                                       mask,
                                       cursor_event_callback,
                                       NULL);
        if (!g_event_tap) {
            *mode_name = "polling";
            return false;
        }
        *mode_name = g_config.mode == MODE_CAPTURE ? "capture-filter-session" : (g_config.mode == MODE_RECENTER ? "recenter-session" : "clamp-session");
    }

    g_event_tap_source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_event_tap, 0);
    if (!g_event_tap_source) {
        CFRelease(g_event_tap);
        g_event_tap = NULL;
        *mode_name = "polling";
        return false;
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), g_event_tap_source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_event_tap, false);
    g_event_tap_enabled = false;
    return true;
}

static void uninstall_event_tap(void) {
    if (g_event_tap_source) {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), g_event_tap_source, kCFRunLoopCommonModes);
        CFRelease(g_event_tap_source);
        g_event_tap_source = NULL;
    }
    if (g_event_tap) {
        CFMachPortInvalidate(g_event_tap);
        CFRelease(g_event_tap);
        g_event_tap = NULL;
    }
    g_event_tap_enabled = false;
}

static void *process_poller_main(void *arg) {
    (void)arg;
    bool last_state = false;
    while (atomic_load(&g_keep_running)) {
        bool active = should_activate();
        pthread_mutex_lock(&g_activation_mutex);
        atomic_store(&g_active, active);
        pthread_mutex_unlock(&g_activation_mutex);
        if (active != last_state) {
            printf("[game-cursor-fence] process gate: %s\n", active ? "active" : "idle");
            debug_log("process-gate active=%s", active ? "true" : "false");
            last_state = active;
        }
        usleep((useconds_t)(g_config.process_poll_seconds * 1000000.0));
    }
    return NULL;
}

static const char *mode_name(CursorMode mode) {
    switch (mode) {
        case MODE_CAPTURE:
            return "capture";
        case MODE_RECENTER:
            return "recenter";
        case MODE_CLAMP:
            return "clamp";
    }
    return "unknown";
}

static void usage(void) {
    puts("Usage: game-cursor-fence [options]\n"
         "\n"
         "Keeps games in relative mouse mode while matching games run.\n"
         "\n"
         "Options:\n"
         "  --process <needle>       Process command-line needle. Can be repeated.\n"
         "  --needle <needle>        Alias for --process.\n"
         "  --provider-games         Activate for non-service Wine game processes from GameHub/CrossOver. Default: enabled.\n"
         "  --no-provider-games      Disable automatic GameHub/CrossOver game detection.\n"
         "  --mode <capture|recenter|clamp>\n"
         "                           capture fences the system cursor and forwards protected raw motion to the game. Default: capture.\n"
         "  --frontmost-gate         Require the matching game application to be frontmost. Default.\n"
         "  --no-frontmost-gate      Keep capture active while a matching game runs in the background.\n"
         "  --polling-fallback       Use polling recenter/clamp if event tap is unavailable. Default: enabled.\n"
         "  --no-polling-fallback    Disable the polling fallback.\n"
         "  --no-process-gate        Keep the helper active even when no matching game is running.\n"
         "  --assume-hidden-cursor   Compatibility no-op; capture no longer depends on cursor visibility.\n"
         "  --min-y <points>         Top fence Y coordinate in screen points. Default: 36.\n"
         "  --fallback-y <points>    Alias for --min-y.\n"
         "  --hz <number>            Active polling rate. Default: 120.\n"
         "  --idle-hz <number>       Idle polling rate. Default: 2.\n"
         "  --process-poll <seconds> Process-list refresh interval. Default: 1.\n"
         "  --log-file <path>        Append logs to path. Useful when launched as a .app.\n"
         "  --debug-log-file <path>  Append diagnostic input logs to path.\n"
         "  --check-pid <pid>         Print whether one process matches the effective game-detection policy.\n"
         "  --check-running           Print whether any matching game process is running.\n"
         "  --check-frontmost         Print whether the current frontmost application matches the game policy.\n"
         "  --dry-run                Print the effective configuration and exit without installing an event tap.\n"
         "  --verbose                Print counters.\n"
         "  --help                   Show this help.");
}

static bool parse_args(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        const char *arg = argv[i];
        if (strcmp(arg, "--help") == 0) {
            usage();
            exit(0);
        } else if (strcmp(arg, "--process") == 0 || strcmp(arg, "--needle") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Missing value for %s\n", arg);
                return false;
            }
            if (g_config.needle_count >= MAX_NEEDLES) {
                fprintf(stderr, "Too many process needles; max is %d\n", MAX_NEEDLES);
                return false;
            }
            g_config.needles[g_config.needle_count++] = argv[i];
        } else if (strcmp(arg, "--provider-games") == 0) {
            g_config.provider_games = true;
        } else if (strcmp(arg, "--no-provider-games") == 0) {
            g_config.provider_games = false;
        } else if (strcmp(arg, "--polling-fallback") == 0) {
            g_config.polling_fallback = true;
        } else if (strcmp(arg, "--no-polling-fallback") == 0) {
            g_config.polling_fallback = false;
        } else if (strcmp(arg, "--no-process-gate") == 0) {
            g_config.process_gate = false;
        } else if (strcmp(arg, "--assume-hidden-cursor") == 0) {
            /* Retained as a compatibility no-op for existing launch scripts. */
        } else if (strcmp(arg, "--no-frontmost-gate") == 0) {
            g_config.frontmost_gate = false;
        } else if (strcmp(arg, "--frontmost-gate") == 0) {
            g_config.frontmost_gate = true;
        } else if (strcmp(arg, "--verbose") == 0) {
            g_config.verbose = true;
        } else if (strcmp(arg, "--mode") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Missing value for %s\n", arg);
                return false;
            }
            if (strcmp(argv[i], "capture") == 0 || strcmp(argv[i], "relative") == 0) {
                g_config.mode = MODE_CAPTURE;
            } else if (strcmp(argv[i], "recenter") == 0) {
                g_config.mode = MODE_RECENTER;
            } else if (strcmp(argv[i], "clamp") == 0) {
                g_config.mode = MODE_CLAMP;
            } else {
                fprintf(stderr, "Invalid value for --mode: %s\n", argv[i]);
                return false;
            }
        } else if (strcmp(arg, "--min-y") == 0 || strcmp(arg, "--fallback-y") == 0) {
            if (++i >= argc || !parse_positive_double(argv[i], &g_config.fence_y)) {
                fprintf(stderr, "Invalid value for %s: %s\n", arg, i < argc ? argv[i] : "");
                return false;
            }
        } else if (strcmp(arg, "--hz") == 0) {
            if (++i >= argc || !parse_positive_double(argv[i], &g_config.hz)) {
                fprintf(stderr, "Invalid value for %s: %s\n", arg, i < argc ? argv[i] : "");
                return false;
            }
        } else if (strcmp(arg, "--idle-hz") == 0) {
            if (++i >= argc || !parse_positive_double(argv[i], &g_config.idle_hz)) {
                fprintf(stderr, "Invalid value for %s: %s\n", arg, i < argc ? argv[i] : "");
                return false;
            }
        } else if (strcmp(arg, "--process-poll") == 0) {
            if (++i >= argc || !parse_positive_double(argv[i], &g_config.process_poll_seconds)) {
                fprintf(stderr, "Invalid value for %s: %s\n", arg, i < argc ? argv[i] : "");
                return false;
            }
        } else if (strcmp(arg, "--log-file") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Missing value for %s\n", arg);
                return false;
            }
            g_config.log_file = argv[i];
        } else if (strcmp(arg, "--debug-log-file") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Missing value for %s\n", arg);
                return false;
            }
            g_config.debug_log_file = argv[i];
        } else if (strcmp(arg, "--dry-run") == 0) {
            g_dry_run = true;
        } else if (strcmp(arg, "--check-pid") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "Missing value for %s\n", arg);
                return false;
            }
            char *end = NULL;
            long parsed_pid = strtol(argv[i], &end, 10);
            if (end == argv[i] || *end != '\0' || parsed_pid <= 0 || parsed_pid > INT_MAX) {
                fprintf(stderr, "Invalid value for %s: %s\n", arg, argv[i]);
                return false;
            }
            g_check_pid = (pid_t)parsed_pid;
        } else if (strcmp(arg, "--check-frontmost") == 0) {
            g_check_frontmost = true;
        } else if (strcmp(arg, "--check-running") == 0) {
            g_check_running = true;
        } else {
            fprintf(stderr, "Unknown option: %s\n\n", arg);
            usage();
            return false;
        }
    }
    return true;
}

static void reopen_logs_if_requested(void) {
    if (!g_config.log_file) {
        return;
    }
    freopen(g_config.log_file, "a", stdout);
    freopen(g_config.log_file, "a", stderr);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

static void open_debug_log_if_requested(void) {
    if (!g_config.debug_log_file) {
        return;
    }
    g_debug_log = fopen(g_config.debug_log_file, "a");
    if (!g_debug_log) {
        fprintf(stderr, "[game-cursor-fence] failed to open debug log: %s\n", g_config.debug_log_file);
        return;
    }
    setvbuf(g_debug_log, NULL, _IONBF, 0);
    debug_log("debug-log-opened path=%s", g_config.debug_log_file);
}

static void polling_fallback_tick(void) {
    if (!atomic_load(&g_active)) {
        return;
    }
    CGEventRef event = CGEventCreate(NULL);
    if (!event) {
        return;
    }
    CGPoint location = CGEventGetLocation(event);
    CFRelease(event);

    if (g_config.mode == MODE_CAPTURE) {
        return;
    } else if (g_config.mode == MODE_RECENTER) {
        warp_cursor_to_top_fence_if_needed(location);
        recenter_cursor_if_needed(location);
    } else if (location.y < g_config.fence_y) {
        location.y = g_config.fence_y;
        CGWarpMouseCursorPosition(location);
        atomic_fetch_add(&g_clamp_count, 1);
    }
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
    signal(SIGTERM, handle_signal);
    signal(SIGINT, handle_signal);

    if (!parse_args(argc, argv)) {
        return 2;
    }
    if (g_check_pid > 0) {
        char command[LINE_SIZE];
        bool matched = read_process_command(g_check_pid, command, sizeof(command)) &&
                       process_matches_config(command, provider_runtime_is_running());
        printf("pid=%d match=%s\n", g_check_pid, matched ? "true" : "false");
        return matched ? 0 : 1;
    }
    if (g_check_running) {
        bool matched = any_matching_process();
        printf("match=%s\n", matched ? "true" : "false");
        return matched ? 0 : 1;
    }
    if (g_check_frontmost) {
        pid_t frontmost_pid = gcf_frontmost_application_pid();
        bool matched = application_pid_matches_config(frontmost_pid);
        printf("pid=%d match=%s\n", frontmost_pid, matched ? "true" : "false");
        return matched ? 0 : 1;
    }
    if (g_dry_run) {
        printf("processGate=%s mode=%s providerGames=%s frontmostGate=%s pollingFallback=%s fenceY=%.1f hz=%.1f idleHz=%.1f\n",
               g_config.process_gate ? "true" : "false",
               mode_name(g_config.mode),
               g_config.provider_games ? "true" : "false",
               g_config.frontmost_gate ? "true" : "false",
               g_config.polling_fallback ? "true" : "false",
               g_config.fence_y,
               g_config.hz,
               g_config.idle_hz);
        return 0;
    }

    int singleton_status = acquire_singleton_lock();
    if (singleton_status == 0) {
        puts("[game-cursor-fence] companion is already running");
        return 0;
    }
    if (singleton_status < 0) {
        return 1;
    }
    reopen_logs_if_requested();
    open_debug_log_if_requested();

    pthread_t poller;
    bool has_poller = false;
    if (g_config.process_gate) {
        has_poller = pthread_create(&poller, NULL, process_poller_main, NULL) == 0;
        if (!has_poller) {
            fprintf(stderr, "[game-cursor-fence] failed to start process poller\n");
        }
    } else {
        atomic_store(&g_active, true);
    }

    const char *tap_mode = "polling";
    bool has_tap = install_event_tap(&tap_mode);
    if (!has_tap && !g_config.polling_fallback) {
        puts("[game-cursor-fence] smooth event tap unavailable; helper is inactive until this binary has Accessibility/Input Monitoring permission.");
    } else if (!has_tap && g_config.polling_fallback) {
        puts("[game-cursor-fence] smooth event tap unavailable; using polling fallback. Grant Accessibility/Input Monitoring for smoother cursor capture.");
    }

    puts("[game-cursor-fence] started");
    printf("[game-cursor-fence] fenceY=%.1fpt hz=%.1f processGate=%s mode=%s tap=%s\n",
           g_config.fence_y,
           g_config.hz,
           g_config.process_gate ? "true" : "false",
           mode_name(g_config.mode),
           tap_mode);
    if (g_config.needle_count > 0) {
        printf("[game-cursor-fence] process needles:");
        for (int i = 0; i < g_config.needle_count; i++) {
            printf("%s%s", i == 0 ? " " : " | ", g_config.needles[i]);
        }
        putchar('\n');
    }
    printf("[game-cursor-fence] providerGames=%s\n", g_config.provider_games ? "true" : "false");
    printf("[game-cursor-fence] frontmostGate=%s\n", g_config.frontmost_gate ? "true" : "false");
    debug_log("started fenceY=%.1f hz=%.1f processGate=%s mode=%s tap=%s providerGames=%s frontmostGate=%s pollingFallback=%s",
              g_config.fence_y,
              g_config.hz,
              g_config.process_gate ? "true" : "false",
              mode_name(g_config.mode),
              tap_mode,
              g_config.provider_games ? "true" : "false",
              g_config.frontmost_gate ? "true" : "false",
              g_config.polling_fallback ? "true" : "false");
    if (g_config.process_gate && g_config.needle_count == 0 && !g_config.provider_games) {
        puts("[game-cursor-fence] no process needles configured");
    }

    bool last_active = false;
    double last_verbose = monotonic_seconds();
    while (atomic_load(&g_keep_running)) {
        bool active = atomic_load(&g_active);
        if (active != last_active) {
            if (g_config.mode == MODE_CAPTURE) {
                set_cursor_detached(active);
                set_cursor_hidden(active);
                if (active) {
                    park_capture_cursor_once();
                }
            }
            if (has_tap) {
                set_event_tap_enabled(active);
            }
            last_active = active;
        }

        if (active && g_config.mode == MODE_CAPTURE) {
            CGEventRef cursor_event = CGEventCreate(NULL);
            if (cursor_event) {
                CGPoint location = CGEventGetLocation(cursor_event);
                capture_watchdog_tick(location);
                CFRelease(cursor_event);
            }
        }

        if (!has_tap && g_config.polling_fallback) {
            polling_fallback_tick();
        }
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.005, true);

        double now = monotonic_seconds();
        if (g_config.verbose && now - last_verbose >= 2.0) {
            printf("[game-cursor-fence] clamps=%lu recenterWarps=%lu captureForwards=%lu captureRecoveries=%lu cursorRehides=%lu\n",
                   atomic_load(&g_clamp_count),
                   atomic_load(&g_recenter_count),
                   atomic_load(&g_capture_forward_count),
                   atomic_load(&g_capture_recovery_count),
                   atomic_load(&g_cursor_rehide_count));
            last_verbose = now;
        }

        double tick_hz = active ? g_config.hz : g_config.idle_hz;
        usleep((useconds_t)(1000000.0 / tick_hz));
    }

    set_cursor_hidden(false);
    set_cursor_detached(false);
    set_event_tap_enabled(false);
    uninstall_event_tap();
    if (has_poller) {
        pthread_join(poller, NULL);
    }
    debug_log("stopped clamps=%lu recenterWarps=%lu captureForwards=%lu captureRecoveries=%lu cursorRehides=%lu",
              atomic_load(&g_clamp_count),
              atomic_load(&g_recenter_count),
              atomic_load(&g_capture_forward_count),
              atomic_load(&g_capture_recovery_count),
              atomic_load(&g_cursor_rehide_count));
    if (g_debug_log) {
        fclose(g_debug_log);
        g_debug_log = NULL;
    }
    if (g_singleton_lock_fd >= 0) {
        close(g_singleton_lock_fd);
        g_singleton_lock_fd = -1;
    }
    puts("[game-cursor-fence] stopped");
    return 0;
}

#include <ApplicationServices/ApplicationServices.h>
#include <AppKit/AppKit.h>
#include <CoreFoundation/CoreFoundation.h>

#include <errno.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

static volatile sig_atomic_t g_keep_running = 1;
static volatile sig_atomic_t g_marker_requests = 0;
static FILE *g_log_file = NULL;
static double g_top_limit = 128.0;
static CFMachPortRef g_event_tap = NULL;

static void handle_signal(int signal_number) {
    if (signal_number == SIGUSR1) {
        g_marker_requests++;
        return;
    }
    g_keep_running = 0;
}

static double monotonic_seconds(void) {
    struct timespec timestamp;
    clock_gettime(CLOCK_MONOTONIC, &timestamp);
    return (double)timestamp.tv_sec + (double)timestamp.tv_nsec / 1000000000.0;
}

static bool parse_nonnegative_double(const char *text, double *value) {
    char *end = NULL;
    errno = 0;
    double parsed = strtod(text, &end);
    if (errno != 0 || end == text || *end != '\0' || parsed < 0.0) {
        return false;
    }
    *value = parsed;
    return true;
}

static CGEventRef trace_event(CGEventTapProxy proxy,
                              CGEventType type,
                              CGEventRef event,
                              void *user_info) {
    (void)proxy;
    (void)user_info;

    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (g_event_tap) {
            CGEventTapEnable(g_event_tap, true);
        }
        return event;
    }

    bool is_motion = type == kCGEventMouseMoved ||
                     type == kCGEventLeftMouseDragged ||
                     type == kCGEventRightMouseDragged ||
                     type == kCGEventOtherMouseDragged;
    bool is_button = type == kCGEventLeftMouseDown ||
                     type == kCGEventLeftMouseUp ||
                     type == kCGEventRightMouseDown ||
                     type == kCGEventRightMouseUp ||
                     type == kCGEventOtherMouseDown ||
                     type == kCGEventOtherMouseUp;
    if (!event || (!is_motion && !is_button)) {
        return event;
    }

    CGPoint location = CGEventGetLocation(event);
    if (!is_button && location.y > g_top_limit) {
        return event;
    }

    int64_t delta_x = CGEventGetIntegerValueField(event, kCGMouseEventDeltaX);
    int64_t delta_y = CGEventGetIntegerValueField(event, kCGMouseEventDeltaY);
    double unaccelerated_x = CGEventGetDoubleValueField(event, kCGEventUnacceleratedPointerMovementX);
    double unaccelerated_y = CGEventGetDoubleValueField(event, kCGEventUnacceleratedPointerMovementY);
    NSEvent *ns_event = [NSEvent eventWithCGEvent:event];
    double ns_delta_x = ns_event ? ns_event.deltaX : 0.0;
    double ns_delta_y = ns_event ? ns_event.deltaY : 0.0;
    int64_t source_pid = CGEventGetIntegerValueField(event, kCGEventSourceUnixProcessID);
    int64_t target_pid = CGEventGetIntegerValueField(event, kCGEventTargetUnixProcessID);
    int64_t source_state = CGEventGetIntegerValueField(event, kCGEventSourceStateID);
    int64_t subtype = CGEventGetIntegerValueField(event, kCGMouseEventSubtype);
    int64_t event_number = CGEventGetIntegerValueField(event, kCGMouseEventNumber);
    int64_t user_data = CGEventGetIntegerValueField(event, kCGEventSourceUserData);
    int64_t window_under = CGEventGetIntegerValueField(
        event,
        kCGMouseEventWindowUnderMousePointer);
    int64_t window_capable = CGEventGetIntegerValueField(
        event,
        kCGMouseEventWindowUnderMousePointerThatCanHandleThisEvent);

    fprintf(g_log_file,
            "EVENT t=%.6f event_ns=%llu type=%u x=%.3f y=%.3f dx=%lld dy=%lld "
            "ux=%.3f uy=%.3f ns_dx=%.3f ns_dy=%.3f "
            "source_pid=%lld target_pid=%lld source_state=%lld subtype=%lld "
            "event_number=%lld user_data=%lld window_under=%lld window_capable=%lld flags=%llu\n",
            monotonic_seconds(),
            (unsigned long long)CGEventGetTimestamp(event),
            (unsigned)type,
            location.x,
            location.y,
            (long long)delta_x,
            (long long)delta_y,
            unaccelerated_x,
            unaccelerated_y,
            ns_delta_x,
            ns_delta_y,
            (long long)source_pid,
            (long long)target_pid,
            (long long)source_state,
            (long long)subtype,
            (long long)event_number,
            (long long)user_data,
            (long long)window_under,
            (long long)window_capable,
            (unsigned long long)CGEventGetFlags(event));
    return event;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 4) {
        fprintf(stderr, "Usage: macos_mouse_event_trace <log-file> [top-limit] [target-pid]\n");
        return 2;
    }
    if (argc == 3 && !parse_nonnegative_double(argv[2], &g_top_limit)) {
        fprintf(stderr, "Invalid top-limit: %s\n", argv[2]);
        return 2;
    }

    pid_t target_pid = 0;
    if (argc == 4) {
        char *end = NULL;
        errno = 0;
        long parsed_pid = strtol(argv[3], &end, 10);
        if (errno != 0 || end == argv[3] || *end != '\0' || parsed_pid <= 0 || parsed_pid > INT32_MAX) {
            fprintf(stderr, "Invalid target PID: %s\n", argv[3]);
            return 2;
        }
        target_pid = (pid_t)parsed_pid;
    }

    g_log_file = fopen(argv[1], "w");
    if (!g_log_file) {
        perror("Unable to open trace log");
        return 3;
    }
    setvbuf(g_log_file, NULL, _IONBF, 0);
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    signal(SIGUSR1, handle_signal);

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

    if (target_pid > 0) {
        g_event_tap = CGEventTapCreateForPid(target_pid,
                                             kCGHeadInsertEventTap,
                                             kCGEventTapOptionListenOnly,
                                             mask,
                                             trace_event,
                                             NULL);
    } else {
        g_event_tap = CGEventTapCreate(kCGHIDEventTap,
                                       kCGHeadInsertEventTap,
                                       kCGEventTapOptionListenOnly,
                                       mask,
                                       trace_event,
                                       NULL);
    }
    if (!g_event_tap) {
        fputs("Unable to install the HID event trace tap.\n", stderr);
        fclose(g_log_file);
        return 4;
    }

    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, g_event_tap, 0);
    if (!source) {
        fputs("Unable to create the trace run-loop source.\n", stderr);
        CFRelease(g_event_tap);
        fclose(g_log_file);
        return 5;
    }

    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CGEventTapEnable(g_event_tap, true);
    fprintf(g_log_file,
            "READY t=%.6f top_limit=%.1f target_pid=%d\n",
            monotonic_seconds(),
            g_top_limit,
            target_pid);
    puts("READY");
    fflush(stdout);

    while (g_keep_running) {
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, true);
        while (g_marker_requests > 0) {
            static unsigned marker_index = 0;
            g_marker_requests--;
            marker_index++;
            fprintf(g_log_file, "MARK t=%.6f index=%u\n", monotonic_seconds(), marker_index);
        }
    }

    fprintf(g_log_file, "STOP t=%.6f\n", monotonic_seconds());
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, kCFRunLoopCommonModes);
    CFRelease(source);
    CFMachPortInvalidate(g_event_tap);
    CFRelease(g_event_tap);
    fclose(g_log_file);
    return 0;
}

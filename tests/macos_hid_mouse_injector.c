#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/hidsystem/IOHIDLib.h>
#include <IOKit/hidsystem/IOHIDParameter.h>
#include <IOKit/hidsystem/IOLLEvent.h>
#include <mach/mach.h>

#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static int parse_integer(const char *text, int minimum, int maximum, const char *name) {
    char *end = NULL;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value < minimum || value > maximum) {
        fprintf(stderr, "Invalid %s: %s\n", name, text);
        exit(2);
    }
    return (int)value;
}

static io_connect_t open_hid_system(void) {
    if (IOHIDCheckAccess(kIOHIDRequestTypePostEvent) != kIOHIDAccessTypeGranted) {
        fputs("IOHID post-event access is not granted.\n", stderr);
        exit(3);
    }

    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching(kIOHIDSystemClass)
    );
    if (service == IO_OBJECT_NULL) {
        fputs("Unable to resolve IOHIDSystem.\n", stderr);
        exit(4);
    }

    io_connect_t connection = IO_OBJECT_NULL;
    kern_return_t result = IOServiceOpen(
        service,
        mach_task_self(),
        kIOHIDParamConnectType,
        &connection
    );
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "Unable to open IOHIDSystem: 0x%x\n", result);
        exit(5);
    }
    return connection;
}

static int post_event(
    io_connect_t connection,
    int event_type,
    IOGPoint location,
    NXEventData *data,
    int options
) {
    kern_return_t result = IOHIDPostEvent(
        connection,
        event_type,
        location,
        data,
        kNXEventDataVersion,
        0,
        options | kIOHIDPostHIDManagerEvent
    );
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "IOHIDPostEvent failed for type %d: 0x%x\n", event_type, result);
        return 6;
    }
    return 0;
}

static int run_move(io_connect_t connection, int argc, char **argv) {
    if (argc != 8) {
        fputs(
            "Usage: macos_hid_mouse_injector move <x> <y> <dx> <dy> <count> <interval-us>\n",
            stderr
        );
        return 2;
    }

    IOGPoint location = {
        .x = parse_integer(argv[2], INT_MIN, INT_MAX, "x"),
        .y = parse_integer(argv[3], INT_MIN, INT_MAX, "y"),
    };
    NXEventData data = {0};
    data.mouseMove.dx = parse_integer(argv[4], INT_MIN, INT_MAX, "dx");
    data.mouseMove.dy = parse_integer(argv[5], INT_MIN, INT_MAX, "dy");
    int count = parse_integer(argv[6], 1, 1000, "count");
    int interval_us = parse_integer(argv[7], 0, 1000000, "interval-us");

    for (int index = 0; index < count; index++) {
        int status = post_event(
            connection,
            NX_MOUSEMOVED,
            location,
            &data,
            kIOHIDSetRelativeCursorPosition
        );
        if (status != 0) {
            return status;
        }
        if (interval_us > 0) {
            usleep((useconds_t)interval_us);
        }
    }
    return 0;
}

static int run_click(io_connect_t connection, int argc, char **argv) {
    if (argc != 4) {
        fputs("Usage: macos_hid_mouse_injector click <x> <y>\n", stderr);
        return 2;
    }

    IOGPoint location = {
        .x = parse_integer(argv[2], INT_MIN, INT_MAX, "x"),
        .y = parse_integer(argv[3], INT_MIN, INT_MAX, "y"),
    };
    NXEventData data = {0};
    data.mouse.click = 1;
    data.mouse.pressure = 255;

    int status = post_event(
        connection,
        NX_LMOUSEDOWN,
        location,
        &data,
        kIOHIDSetCursorPosition
    );
    if (status != 0) {
        return status;
    }
    usleep(20 * 1000);
    data.mouse.pressure = 0;
    return post_event(
        connection,
        NX_LMOUSEUP,
        location,
        &data,
        kIOHIDSetCursorPosition
    );
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fputs(
            "Usage: macos_hid_mouse_injector <move|click> [arguments]\n",
            stderr
        );
        return 2;
    }

    io_connect_t connection = open_hid_system();
    int status = 2;
    if (strcmp(argv[1], "move") == 0) {
        status = run_move(connection, argc, argv);
    } else if (strcmp(argv[1], "click") == 0) {
        status = run_click(connection, argc, argv);
    } else {
        fprintf(stderr, "Unknown action: %s\n", argv[1]);
    }
    IOServiceClose(connection);
    return status;
}

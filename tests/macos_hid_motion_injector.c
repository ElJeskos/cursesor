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

int main(int argc, char **argv) {
    if (argc != 7) {
        fprintf(stderr,
                "Usage: macos_hid_motion_injector <x> <y> <dx> <dy> <count> <interval-us>\n");
        return 2;
    }

    int x = parse_integer(argv[1], INT_MIN, INT_MAX, "x");
    int y = parse_integer(argv[2], INT_MIN, INT_MAX, "y");
    int dx = parse_integer(argv[3], INT_MIN, INT_MAX, "dx");
    int dy = parse_integer(argv[4], INT_MIN, INT_MAX, "dy");
    int count = parse_integer(argv[5], 1, 1000, "count");
    int interval_us = parse_integer(argv[6], 0, 1000000, "interval-us");

    if (IOHIDCheckAccess(kIOHIDRequestTypePostEvent) != kIOHIDAccessTypeGranted) {
        fputs("IOHID post-event access is not granted.\n", stderr);
        return 3;
    }

    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault,
        IOServiceMatching(kIOHIDSystemClass)
    );
    if (service == IO_OBJECT_NULL) {
        fputs("Unable to resolve IOHIDSystem.\n", stderr);
        return 4;
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
        return 5;
    }

    IOGPoint location = {
        .x = x,
        .y = y,
    };
    NXEventData data = {0};
    data.mouseMove.dx = dx;
    data.mouseMove.dy = dy;

    for (int index = 0; index < count; index++) {
        result = IOHIDPostEvent(
            connection,
            NX_MOUSEMOVED,
            location,
            &data,
            kNXEventDataVersion,
            0,
            kIOHIDSetRelativeCursorPosition | kIOHIDPostHIDManagerEvent
        );
        if (result != KERN_SUCCESS) {
            fprintf(stderr, "IOHIDPostEvent failed at event %d: 0x%x\n", index + 1, result);
            IOServiceClose(connection);
            return 6;
        }
        if (interval_us > 0) {
            usleep((useconds_t)interval_us);
        }
    }

    IOServiceClose(connection);
    return 0;
}

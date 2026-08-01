#import <AppKit/AppKit.h>

#import "frontmost_app.h"

pid_t gcf_frontmost_application_pid(void) {
    @autoreleasepool {
        NSRunningApplication *application = [[NSWorkspace sharedWorkspace] frontmostApplication];
        return application ? [application processIdentifier] : 0;
    }
}

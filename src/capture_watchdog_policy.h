#ifndef GCF_CAPTURE_WATCHDOG_POLICY_H
#define GCF_CAPTURE_WATCHDOG_POLICY_H

#include <stdbool.h>

typedef struct {
    bool recovery_latched;
    bool hidden_timer_started;
    double hidden_since;
} GCFCaptureWatchdogState;

typedef struct {
    bool should_rehide;
    bool should_reassociate;
} GCFCaptureWatchdogDecision;

GCFCaptureWatchdogDecision gcf_capture_watchdog_update(GCFCaptureWatchdogState *state,
                                                        bool cursor_visible,
                                                        double now);

#endif

#include "capture_watchdog_policy.h"

#include <stddef.h>

static const double kStableHiddenResetSeconds = 0.50;

GCFCaptureWatchdogDecision gcf_capture_watchdog_update(GCFCaptureWatchdogState *state,
                                                        bool cursor_visible,
                                                        double now) {
    GCFCaptureWatchdogDecision decision = {0};
    if (!state) {
        return decision;
    }

    if (cursor_visible) {
        decision.should_rehide = true;
        decision.should_reassociate = !state->recovery_latched;
        state->recovery_latched = true;
        state->hidden_timer_started = false;
        return decision;
    }

    if (!state->recovery_latched) {
        state->hidden_timer_started = false;
        return decision;
    }

    if (!state->hidden_timer_started || now < state->hidden_since) {
        state->hidden_since = now;
        state->hidden_timer_started = true;
        return decision;
    }

    if (now - state->hidden_since >= kStableHiddenResetSeconds) {
        state->recovery_latched = false;
        state->hidden_timer_started = false;
    }

    return decision;
}

#include "../src/capture_watchdog_policy.h"

#include <stdio.h>

typedef struct {
    const char *name;
    bool cursor_visible;
    double now;
    bool expected_rehide;
    bool expected_reassociate;
    bool expected_latched;
} TestCase;

int main(void) {
    const TestCase cases[] = {
        {
            .name = "initial hidden sample",
            .cursor_visible = false,
            .now = 0.00,
            .expected_rehide = false,
            .expected_reassociate = false,
            .expected_latched = false,
        },
        {
            .name = "first visibility breach",
            .cursor_visible = true,
            .now = 0.10,
            .expected_rehide = true,
            .expected_reassociate = true,
            .expected_latched = true,
        },
        {
            .name = "continuous Wine visibility pressure",
            .cursor_visible = true,
            .now = 0.11,
            .expected_rehide = true,
            .expected_reassociate = false,
            .expected_latched = true,
        },
        {
            .name = "short hidden interval keeps recovery latched",
            .cursor_visible = false,
            .now = 0.30,
            .expected_rehide = false,
            .expected_reassociate = false,
            .expected_latched = true,
        },
        {
            .name = "stable hidden interval resets recovery",
            .cursor_visible = false,
            .now = 0.90,
            .expected_rehide = false,
            .expected_reassociate = false,
            .expected_latched = false,
        },
        {
            .name = "later independent visibility breach",
            .cursor_visible = true,
            .now = 1.00,
            .expected_rehide = true,
            .expected_reassociate = true,
            .expected_latched = true,
        },
    };

    int failures = 0;
    GCFCaptureWatchdogState state = {0};
    size_t count = sizeof(cases) / sizeof(cases[0]);
    for (size_t index = 0; index < count; index++) {
        GCFCaptureWatchdogDecision actual = gcf_capture_watchdog_update(
            &state,
            cases[index].cursor_visible,
            cases[index].now
        );
        if (actual.should_rehide != cases[index].expected_rehide ||
            actual.should_reassociate != cases[index].expected_reassociate ||
            state.recovery_latched != cases[index].expected_latched) {
            fprintf(stderr,
                    "FAIL: %s expected rehide=%s reassociate=%s latched=%s observed rehide=%s reassociate=%s latched=%s\n",
                    cases[index].name,
                    cases[index].expected_rehide ? "true" : "false",
                    cases[index].expected_reassociate ? "true" : "false",
                    cases[index].expected_latched ? "true" : "false",
                    actual.should_rehide ? "true" : "false",
                    actual.should_reassociate ? "true" : "false",
                    state.recovery_latched ? "true" : "false");
            failures++;
        }
    }

    if (failures != 0) {
        return 1;
    }

    printf("PASS: %zu capture-watchdog policy cases.\n", count);
    return 0;
}

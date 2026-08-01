#include "../src/capture_edge_policy.h"

#include <stdbool.h>
#include <stdio.h>

typedef struct {
    const char *name;
    double location_y;
    double protected_top;
    bool expected;
} TestCase;

int main(void) {
    const TestCase cases[] = {
        {
            .name = "desktop top click",
            .location_y = 0.0,
            .protected_top = 36.5,
            .expected = true,
        },
        {
            .name = "RDR2 top strip click",
            .location_y = 33.0,
            .protected_top = 36.5,
            .expected = true,
        },
        {
            .name = "game-content click",
            .location_y = 37.0,
            .protected_top = 36.5,
            .expected = false,
        },
        {
            .name = "invalid location",
            .location_y = __builtin_nan(""),
            .protected_top = 36.5,
            .expected = false,
        },
        {
            .name = "invalid boundary",
            .location_y = 0.0,
            .protected_top = __builtin_nan(""),
            .expected = false,
        },
    };

    int failures = 0;
    size_t count = sizeof(cases) / sizeof(cases[0]);
    for (size_t index = 0; index < count; index++) {
        bool actual = gcf_capture_edge_should_suppress_button(
            cases[index].location_y,
            cases[index].protected_top
        );
        if (actual != cases[index].expected) {
            fprintf(stderr,
                    "FAIL: %s expected suppress=%s observed=%s\n",
                    cases[index].name,
                    cases[index].expected ? "true" : "false",
                    actual ? "true" : "false");
            failures++;
        }
    }

    if (failures != 0) {
        return 1;
    }

    printf("PASS: %zu protected top-button cases.\n", count);
    return 0;
}

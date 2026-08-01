#include <ApplicationServices/ApplicationServices.h>

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
    if (argc != 3) {
        fputs("Usage: macos_cursor_visibility_probe <sample-count> <interval-us>\n", stderr);
        return 2;
    }

    int sample_count = parse_integer(argv[1], 1, 1000000, "sample-count");
    int interval_us = parse_integer(argv[2], 100, 1000000, "interval-us");
    int visible_samples = 0;

    puts("READY");
    fflush(stdout);
    for (int index = 0; index < sample_count; index++) {
        if (CGCursorIsVisible()) {
            if (visible_samples == 0) {
                printf("FIRST_VISIBLE sample=%d\n", index);
            }
            visible_samples++;
        }
        usleep((useconds_t)interval_us);
    }
    printf("RESULT visible_samples=%d total_samples=%d\n", visible_samples, sample_count);
    return visible_samples == 0 ? 0 : 1;
}

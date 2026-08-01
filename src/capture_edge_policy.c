#include "capture_edge_policy.h"

#include <math.h>

bool gcf_capture_edge_should_suppress_button(double location_y,
                                             double protected_top) {
    return isfinite(location_y) &&
           isfinite(protected_top) &&
           location_y <= protected_top;
}

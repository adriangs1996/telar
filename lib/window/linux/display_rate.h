#pragma once
#include <stdbool.h>
#include <stdint.h>
#include "outputs.h"

// Window-thread follower of the outputs the window's surface is on, and the
// refresh interval of the fastest of them. Holds no allocation.
typedef struct {
    telar_outputs *outputs;
    telar_output_set set;
    uint64_t reported_ns;
    bool changed;
} telar_display_rate;


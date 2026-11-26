#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// NSEventPhase bit values mirrored for pure C++ scroll tests.
enum TelarTestScrollPhaseBits {
  telar_test_scroll_phase_none = 0,
  telar_test_scroll_phase_began = 1,
  telar_test_scroll_phase_stationary = 2,
  telar_test_scroll_phase_changed = 4,
  telar_test_scroll_phase_ended = 8,
  telar_test_scroll_phase_cancelled = 16,
  telar_test_scroll_phase_may_begin = 32,
};

#ifdef __cplusplus
[[tbc::raw]]
#endif
void* telarTestScrollEventCreate(const void* ns_view, double x, double y, double delta, bool precise);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void telarTestScrollEventConfigure(void* event, uint64_t phase_bits, uint64_t momentum_bits, double delta, bool precise);

#ifdef __cplusplus
[[tbc::raw]]
#endif
void telarTestScrollEventDestroy(void* event);

#ifdef __cplusplus
}
#endif

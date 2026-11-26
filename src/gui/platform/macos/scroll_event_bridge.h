#pragma once

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct TelarGuiNativeScrollInput {
  double delta;
  double x;
  double y;
  uint8_t phase;
  bool precise;
  bool valid;
} TelarGuiNativeScrollInput;

#ifdef __cplusplus
[[tbc::raw]]
#endif
bool telarGuiReadNativeScrollInput(const void* event_message, const void* ns_view, TelarGuiNativeScrollInput* out);

#ifdef __cplusplus
}
#endif

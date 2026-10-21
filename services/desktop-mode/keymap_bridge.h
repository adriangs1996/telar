#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

enum TelarKeyPhase {
  TELAR_KEY_PRESS = 1,
  TELAR_KEY_REPEAT = 2,
  TELAR_KEY_RELEASE = 3
};

typedef struct {
  const char *keys[5];
  size_t count;
  uint64_t action;
} TelarKeyBinding;

typedef struct {
  const char *chord;
  uint32_t physical;
  uint32_t phase;
} TelarShortcutKey;

void *telar_keymap_create(void);
void telar_keymap_destroy(void *router);
const char *telar_keymap_configure(void *router,
                                   const char *prefix,
                                   const TelarKeyBinding *bindings,
                                   size_t count);
bool telar_keymap_route(void *router, const TelarShortcutKey *key, uint64_t *action);
bool telar_keymap_pending(const void *router);
void telar_keymap_cancel(void *router);

#ifdef __cplusplus
}
#endif

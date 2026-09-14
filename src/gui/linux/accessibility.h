#ifndef TELAR_ACCESSIBILITY_H
#define TELAR_ACCESSIBILITY_H
#include "../native/telar_gui.h"

typedef struct telar_accessibility telar_accessibility;
telar_accessibility *telar_accessibility_create(void *, const telar_gui_callbacks *);
void telar_accessibility_update(telar_accessibility *);
void telar_accessibility_dispatch(telar_accessibility *);
int telar_accessibility_fd(telar_accessibility *);
void telar_accessibility_destroy(telar_accessibility *);
#endif

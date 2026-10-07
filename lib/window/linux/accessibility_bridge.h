#pragma once
#include "../native/telar_gui.h"
#include <stdbool.h>
typedef struct _AtkObject AtkObject;
typedef struct telar_accessibility telar_accessibility;

#define TELAR_ACCESSIBLE_LABEL_CAPACITY 512
#define TELAR_ACCESSIBLE_ACTION_CAPACITY 32

struct accessible_node {
    telar_gui_accessibility_node value;
    char label[TELAR_ACCESSIBLE_LABEL_CAPACITY + 1];
    char text[TELAR_GUI_TEXT_CAPACITY + 1];
};

struct accessible_snapshot {
    uint64_t revision;
    uint32_t count;
    struct accessible_node nodes[TELAR_GUI_ACCESSIBILITY_CAPACITY];
};

struct accessible_action {
    telar_gui_input event;
    uint8_t text[TELAR_GUI_TEXT_CAPACITY + 1];
};

// GObject-visible view, owned only by the AT-SPI worker. Scheduling, snapshots,
// queues and lifecycle live in Accessibility.zig; owner is its stable address.
struct telar_accessibility {
    void *owner;
    AtkObject *root, *objects[TELAR_GUI_ACCESSIBILITY_CAPACITY];
    uint32_t count;
};

AtkObject *telar_accessible_new(telar_accessibility *, const telar_gui_accessibility_node *);
bool telar_accessible_matches(AtkObject *, const telar_gui_accessibility_node *);
uint64_t telar_accessible_id(AtkObject *);
void telar_accessible_update(AtkObject *, const telar_gui_accessibility_node *);
void telar_accessible_detach(AtkObject *);
AtkObject *telar_accessibility_find(telar_accessibility *, uint64_t id);
bool telar_accessibility_enqueue(telar_accessibility *, telar_gui_input);
// ATK class registration stays in the native ABI adapter. Zig owns its worker.
bool telar_accessible_start(telar_accessibility *);
void telar_accessible_stop(void);

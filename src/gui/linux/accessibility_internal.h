#ifndef TELAR_ACCESSIBILITY_INTERNAL_H
#define TELAR_ACCESSIBILITY_INTERNAL_H
#include "accessibility.h"
#include <atk/atk.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>

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

struct telar_accessibility {
    void *context;
    telar_gui_callbacks callbacks;
    pthread_t worker;
    pthread_mutex_t lock;
    int updates[2], actions_wake[2];
    atomic_bool stopping;
    GMainLoop *loop;
    bool dirty, published;
    uint64_t published_revision;
    struct accessible_snapshot pending, current;
    struct accessible_action actions[TELAR_ACCESSIBLE_ACTION_CAPACITY];
    size_t action_start, action_count;
    bool action_admitted;
    // The AT-SPI worker owns every GObject and its current tree.
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
#endif

#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include "registry.h"

// One bit per slot in a set's mask, so the table holds at most this many.
#define TELAR_OUTPUT_LIMIT 32
#define TELAR_OUTPUT_SETS 4

struct telar_outputs;

typedef struct {
    struct wl_output *handle;
    struct telar_outputs *owner;
    uint32_t global;
    int32_t scale;
    // The current mode's refresh in millihertz; zero while the compositor
    // reports none, as a virtual output may.
    uint32_t refresh_mhz;
} telar_output;

// The outputs one surface has entered, one bit per table slot. The table
// clears a slot's bit in every watched set when it frees the slot, so an
// output bound later into that slot never counts as entered.
typedef struct {
    uint32_t entered;
    // Runs when an entered output changes its scale or mode, or goes away.
    void (*changed)(void *data);
    void *data;
} telar_output_set;

// Window-thread owner of every wl_output, bound once and shared by the
// surfaces that follow them. Holds no allocation.
typedef struct telar_outputs {
    telar_output slots[TELAR_OUTPUT_LIMIT];
    telar_output_set *sets[TELAR_OUTPUT_SETS];
    size_t set_count;
} telar_outputs;

void telar_outputs_global(telar_outputs *self, const telar_registry_global *global);
void telar_outputs_remove(telar_outputs *self, uint32_t name);
// Example: if (!telar_outputs_watch(outputs, &theme->set)) return NULL;
bool telar_outputs_watch(telar_outputs *self, telar_output_set *set);
void telar_outputs_unwatch(telar_outputs *self, telar_output_set *set);
// A surface's enter or leave; a NULL or unknown output changes nothing.
// True when the set changed. Example: if (telar_outputs_enter(o, &set, output)) update(self);
bool telar_outputs_enter(telar_outputs *self, telar_output_set *set, struct wl_output *handle);
bool telar_outputs_leave(telar_outputs *self, telar_output_set *set, struct wl_output *handle);
void telar_outputs_deinit(telar_outputs *self);

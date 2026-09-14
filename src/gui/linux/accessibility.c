#define _GNU_SOURCE
#include "accessibility_internal.h"
#include <atk-bridge.h>
#include <glib-unix.h>
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

// Telar has one native window per process; the ATK adaptor has one root.
static telar_accessibility *active_bridge;

static void wake(int fd) {
    uint8_t byte = 1;
    ssize_t result;
    do { result = write(fd, &byte, 1); } while (result < 0 && errno == EINTR);
}

static void drain(int fd) {
    uint8_t bytes[64];
    while (read(fd, bytes, sizeof bytes) > 0) {}
}

AtkObject *telar_accessibility_find(telar_accessibility *self, uint64_t id) {
    if (id == 0) return self->root;
    for (uint32_t i = 0; i < self->count; i++) {
        if (telar_accessible_id(self->objects[i]) == id) return self->objects[i];
    }
    return NULL;
}

bool telar_accessibility_enqueue(telar_accessibility *self, telar_gui_input event) {
    if (self == NULL || event.len > TELAR_GUI_TEXT_CAPACITY || (event.len != 0 && (event.text == NULL || !g_utf8_validate((const char *)event.text, (gssize)event.len, NULL)))) return false;
    pthread_mutex_lock(&self->lock);
    if (atomic_load_explicit(&self->stopping, memory_order_acquire) || self->action_count == TELAR_ACCESSIBLE_ACTION_CAPACITY) {
        pthread_mutex_unlock(&self->lock);
        return false;
    }
    size_t index = (self->action_start + self->action_count) % TELAR_ACCESSIBLE_ACTION_CAPACITY;
    struct accessible_action *action = &self->actions[index];
    action->event = event;
    if (event.len != 0) memcpy(action->text, event.text, event.len);
    action->event.text = action->text;
    self->action_count++;
    pthread_mutex_unlock(&self->lock);
    wake(self->actions_wake[1]);
    return true;
}

static void apply_snapshot(telar_accessibility *self) {
    AtkObject *previous_objects[TELAR_GUI_ACCESSIBILITY_CAPACITY];
    memcpy(previous_objects, self->objects, sizeof previous_objects);
    uint32_t previous_count = self->count;
    AtkObject *replacement[TELAR_GUI_ACCESSIBILITY_CAPACITY] = {0};
    bool retained[TELAR_GUI_ACCESSIBILITY_CAPACITY] = {false};
    bool topology_changed = self->count != self->current.count;
    for (uint32_t i = 0; !topology_changed && i < self->count; i++) {
        topology_changed = !telar_accessible_matches(self->objects[i], &self->current.nodes[i].value) || telar_accessible_id(atk_object_get_parent(self->objects[i])) != self->current.nodes[i].value.parent_id;
    }
    if (topology_changed) {
        gint count = atk_object_get_n_accessible_children(self->root);
        for (gint i = count - 1; i >= 0; i--) {
            AtkObject *child = atk_object_ref_accessible_child(self->root, i);
            g_signal_emit_by_name(self->root, "children-changed::remove", i, child, NULL);
            g_object_unref(child);
        }
    }
    for (uint32_t i = 0; i < self->current.count; i++) {
        struct accessible_node *entry = &self->current.nodes[i];
        entry->value.label = (const uint8_t *)entry->label;
        entry->value.value = (const uint8_t *)entry->text;
        for (uint32_t previous = 0; previous < self->count; previous++) {
            if (!retained[previous] && telar_accessible_matches(self->objects[previous], &entry->value)) {
                replacement[i] = self->objects[previous];
                retained[previous] = true;
                break;
            }
        }
        if (replacement[i] == NULL) replacement[i] = telar_accessible_new(self, &entry->value);
    }
    memcpy(self->objects, replacement, sizeof replacement);
    self->count = self->current.count;
    for (uint32_t i = 0; i < previous_count; i++) {
        if (!retained[i]) {
            telar_accessible_detach(previous_objects[i]);
            g_object_unref(previous_objects[i]);
        }
    }
    for (uint32_t i = 0; i < self->count; i++) telar_accessible_update(self->objects[i], &self->current.nodes[i].value);
    if (topology_changed) {
        gint count = atk_object_get_n_accessible_children(self->root);
        for (gint i = 0; i < count; i++) {
            AtkObject *child = atk_object_ref_accessible_child(self->root, i);
            g_signal_emit_by_name(self->root, "children-changed::add", i, child, NULL);
            g_object_unref(child);
        }
    }
    g_signal_emit_by_name(self->root, "visible-data-changed");
}

static gboolean updated(gint fd, GIOCondition condition, gpointer data) {
    (void)condition;
    telar_accessibility *self = data;
    drain(fd);
    if (atomic_load_explicit(&self->stopping, memory_order_acquire)) {
        g_main_loop_quit(self->loop);
        return G_SOURCE_CONTINUE;
    }
    pthread_mutex_lock(&self->lock);
    bool dirty = self->dirty;
    if (dirty) memcpy(&self->current, &self->pending, sizeof self->current);
    self->dirty = false;
    pthread_mutex_unlock(&self->lock);
    if (dirty) apply_snapshot(self);
    // A publication may have skipped a busy handoff. Let the window retry its
    // newest revision once, without polling either thread while idle.
    wake(self->actions_wake[1]);
    return G_SOURCE_CONTINUE;
}

static AtkObject *root_object(void) { return active_bridge == NULL ? NULL : active_bridge->root; }
static const gchar *toolkit_name(void) { return "Telar"; }
static const gchar *toolkit_version(void) { return "1"; }

static void *run(void *data) {
    telar_accessibility *self = data;
    active_bridge = self;
    self->root = telar_accessible_new(self, NULL);
    AtkUtilClass *util = g_type_class_ref(ATK_TYPE_UTIL);
    util->get_root = root_object;
    util->get_toolkit_name = toolkit_name;
    util->get_toolkit_version = toolkit_version;
    int argc = 0;
    char **argv = NULL;
    bool initialized = atk_bridge_adaptor_init(&argc, &argv) == 0;
    if (!initialized) fprintf(stderr, "telar gui: AT-SPI accessibility bus unavailable; semantic UI remains local\n");
    GSource *source = g_unix_fd_source_new(self->updates[0], G_IO_IN);
    g_source_set_callback(source, G_SOURCE_FUNC(updated), self, NULL);
    g_source_attach(source, NULL);
    if (!atomic_load_explicit(&self->stopping, memory_order_acquire)) g_main_loop_run(self->loop);
    g_source_destroy(source);
    g_source_unref(source);
    if (initialized) atk_bridge_adaptor_cleanup();
    AtkObject *retired[TELAR_GUI_ACCESSIBILITY_CAPACITY];
    memcpy(retired, self->objects, sizeof retired);
    uint32_t retired_count = self->count;
    memset(self->objects, 0, sizeof self->objects);
    self->count = 0;
    for (uint32_t i = 0; i < retired_count; i++) {
        telar_accessible_detach(retired[i]);
        g_object_unref(retired[i]);
    }
    telar_accessible_detach(self->root);
    g_object_unref(self->root);
    self->root = NULL;
    active_bridge = NULL;
    g_type_class_unref(util);
    return NULL;
}

telar_accessibility *telar_accessibility_create(void *context, const telar_gui_callbacks *callbacks) {
    if (callbacks->accessibility == NULL) return NULL;
    telar_accessibility *self = calloc(1, sizeof *self);
    if (self == NULL) return NULL;
    self->context = context;
    self->callbacks = *callbacks;
    atomic_init(&self->stopping, false);
    if (pthread_mutex_init(&self->lock, NULL) != 0) { free(self); return NULL; }
    if (pipe2(self->updates, O_NONBLOCK | O_CLOEXEC) != 0) { pthread_mutex_destroy(&self->lock); free(self); return NULL; }
    if (pipe2(self->actions_wake, O_NONBLOCK | O_CLOEXEC) != 0) {
        close(self->updates[0]); close(self->updates[1]); pthread_mutex_destroy(&self->lock); free(self); return NULL;
    }
    self->loop = g_main_loop_new(NULL, FALSE);
    if (pthread_create(&self->worker, NULL, run, self) != 0) {
        g_main_loop_unref(self->loop);
        close(self->updates[0]); close(self->updates[1]); close(self->actions_wake[0]); close(self->actions_wake[1]);
        pthread_mutex_destroy(&self->lock); free(self); return NULL;
    }
    return self;
}

static bool valid_tree(const telar_gui_accessibility_tree *tree) {
    if (tree->count > TELAR_GUI_ACCESSIBILITY_CAPACITY || (tree->count != 0 && tree->nodes == NULL)) return false;
    for (uint32_t i = 0; i < tree->count; i++) {
        const telar_gui_accessibility_node *node = &tree->nodes[i];
        if (node->id == 0 || node->label_len > TELAR_ACCESSIBLE_LABEL_CAPACITY || node->value_len > TELAR_GUI_TEXT_CAPACITY || (node->label_len != 0 && (node->label == NULL || !g_utf8_validate((const char *)node->label, (gssize)node->label_len, NULL))) || (node->value_len != 0 && (node->value == NULL || !g_utf8_validate((const char *)node->value, (gssize)node->value_len, NULL)))) return false;
        if (!isfinite(node->x) || !isfinite(node->y) || !isfinite(node->width) || !isfinite(node->height) || node->width < 0 || node->height < 0) return false;
        if (node->selection_start > node->value_len || node->selection_end > node->value_len) return false;
        if ((node->selection_start < node->value_len && (node->value[node->selection_start] & 0xc0) == 0x80) || (node->selection_end < node->value_len && (node->value[node->selection_end] & 0xc0) == 0x80)) return false;
        bool parent_found = node->parent_id == 0;
        for (uint32_t previous = 0; previous < i; previous++) {
            if (tree->nodes[previous].id == node->id) return false;
            parent_found |= tree->nodes[previous].id == node->parent_id;
        }
        if (!parent_found) return false;
    }
    return true;
}

void telar_accessibility_update(telar_accessibility *self) {
    if (self == NULL) return;
    telar_gui_accessibility_tree tree = {0};
    self->callbacks.accessibility(self->context, &tree);
    if (self->published && tree.revision == self->published_revision) return;
    if (!valid_tree(&tree) || pthread_mutex_trylock(&self->lock) != 0) return;
    self->pending.count = tree.count;
    self->pending.revision = tree.revision;
    for (uint32_t i = 0; i < tree.count; i++) {
        struct accessible_node *destination = &self->pending.nodes[i];
        destination->value = tree.nodes[i];
        if (tree.nodes[i].label_len != 0) memcpy(destination->label, tree.nodes[i].label, tree.nodes[i].label_len);
        destination->label[tree.nodes[i].label_len] = 0;
        if (tree.nodes[i].value_len != 0) memcpy(destination->text, tree.nodes[i].value, tree.nodes[i].value_len);
        destination->text[tree.nodes[i].value_len] = 0;
    }
    self->dirty = true;
    self->published_revision = tree.revision;
    self->published = true;
    pthread_mutex_unlock(&self->lock);
    wake(self->updates[1]);
}

void telar_accessibility_dispatch(telar_accessibility *self) {
    if (self == NULL) return;
    for (unsigned delivered = 0; delivered < TELAR_ACCESSIBLE_ACTION_CAPACITY; delivered++) {
        if (pthread_mutex_trylock(&self->lock) != 0) return;
        if (self->action_admitted) {
            self->action_start = (self->action_start + 1) % TELAR_ACCESSIBLE_ACTION_CAPACITY;
            self->action_count--;
            self->action_admitted = false;
        }
        if (self->action_count == 0) {
            drain(self->actions_wake[0]);
            pthread_mutex_unlock(&self->lock);
            return;
        }
        struct accessible_action *action = &self->actions[self->action_start];
        // The producer never changes occupied slots. Keep this slot reserved
        // while Zig copies the event, without holding the handoff lock.
        telar_gui_input event = action->event;
        pthread_mutex_unlock(&self->lock);
        if (!self->callbacks.input(self->context, event)) {
            // The client retries after its next pump. A retained queue item
            // must not leave poll readable while its outbox is blocked.
            drain(self->actions_wake[0]);
            return;
        }
        self->action_admitted = true;
        if (pthread_mutex_trylock(&self->lock) != 0) return;
        self->action_start = (self->action_start + 1) % TELAR_ACCESSIBLE_ACTION_CAPACITY;
        self->action_count--;
        self->action_admitted = false;
        pthread_mutex_unlock(&self->lock);
    }
}

int telar_accessibility_fd(telar_accessibility *self) { return self == NULL ? -1 : self->actions_wake[0]; }

void telar_accessibility_destroy(telar_accessibility *self) {
    if (self == NULL) return;
    atomic_store_explicit(&self->stopping, true, memory_order_release);
    wake(self->updates[1]);
    pthread_join(self->worker, NULL);
    g_main_loop_unref(self->loop);
    close(self->updates[0]); close(self->updates[1]); close(self->actions_wake[0]); close(self->actions_wake[1]);
    pthread_mutex_destroy(&self->lock);
    free(self);
}

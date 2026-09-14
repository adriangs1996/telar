#define _GNU_SOURCE
#include "accessibility.c"
#include <assert.h>
#include <poll.h>
#include <time.h>

struct fixture {
    pthread_t owner;
    telar_gui_input events[64];
    char text[64][TELAR_GUI_TEXT_CAPACITY + 1];
    size_t count;
    bool refuse, finished;
    pthread_mutex_t *hold_after_capture;
};

static telar_gui_accessibility_node nodes[] = {
    {.id = 1, .generation = 7, .role = 1, .flags = 1, .x = 10, .y = 20, .width = 300, .height = 100, .label = (const uint8_t *)"Content", .label_len = 7},
    {.id = 2, .generation = 9, .text_revision = 42, .parent_id = 1, .role = 3, .flags = 1 | 2 | 8, .actions = 2 | 4 | 8 | 64 | 128 | 256 | 512, .x = 30, .y = 40, .width = 120, .height = 30, .label = (const uint8_t *)"Name", .label_len = 4, .value = (const uint8_t *)"a界b", .value_len = 5, .selection_start = 1, .selection_end = 4},
    {.id = 3, .generation = 11, .parent_id = 1, .role = 2, .flags = 1, .actions = 1 | 2, .x = 170, .y = 40, .width = 60, .height = 30, .label = (const uint8_t *)"Finish", .label_len = 6},
};

static int capture(void *context, telar_gui_input event) {
    struct fixture *self = context;
    assert(pthread_equal(self->owner, pthread_self()));
    if (self->refuse) return 0;
    assert(self->count < 64);
    self->events[self->count] = event;
    if (event.len != 0) memcpy(self->text[self->count], event.text, event.len);
    self->text[self->count][event.len] = 0;
    self->events[self->count].text = (const uint8_t *)self->text[self->count];
    self->count++;
    self->finished |= event.target_id == 3 && event.code == 1;
    if (self->hold_after_capture != NULL) pthread_mutex_lock(self->hold_after_capture);
    return 1;
}

static int tree(void *context, telar_gui_accessibility_tree *result) {
    assert(pthread_equal(((struct fixture *)context)->owner, pthread_self()));
    *result = (telar_gui_accessibility_tree){.revision = 1, .nodes = nodes, .count = 3};
    return 1;
}

static unsigned retired_notifications;
static void on_retired(AtkObject *object, const gchar *state, gboolean enabled, gpointer data) {
    (void)object;
    if (strcmp(state, "defunct") != 0 || !enabled) return;
    telar_accessibility *bridge = data;
    // ATK emits synchronously. An observer may enumerate the application while
    // the old snapshot is being released, including its second/third removal.
    assert(atk_object_get_n_accessible_children(bridge->root) == 0);
    assert(atk_object_ref_accessible_child(bridge->root, 0) == NULL);
    assert(bridge->count == 0);
    retired_notifications++;
}

static void unit(void) {
    struct fixture fixture = {.owner = pthread_self()};
    telar_accessibility *bridge = calloc(1, sizeof *bridge);
    assert(bridge != NULL);
    bridge->context = &fixture;
    bridge->callbacks = (telar_gui_callbacks){.input = capture, .accessibility = tree};
    atomic_init(&bridge->stopping, false);
    assert(pthread_mutex_init(&bridge->lock, NULL) == 0);
    assert(pipe2(bridge->updates, O_NONBLOCK | O_CLOEXEC) == 0);
    assert(pipe2(bridge->actions_wake, O_NONBLOCK | O_CLOEXEC) == 0);
    bridge->root = telar_accessible_new(bridge, NULL);
    telar_accessibility_update(bridge);
    assert(bridge->dirty);
    memcpy(&bridge->current, &bridge->pending, sizeof bridge->current);
    apply_snapshot(bridge);
    assert(atk_object_get_n_accessible_children(bridge->root) == 1);
    AtkObject *group = bridge->objects[0], *field = bridge->objects[1], *button = bridge->objects[2];
    assert(atk_object_get_parent(field) == group);
    assert(atk_object_get_n_accessible_children(group) == 2);
    assert(atk_object_get_index_in_parent(button) == 1);
    assert(atk_object_get_role(field) == ATK_ROLE_ENTRY);
    assert(atk_object_get_role(button) == ATK_ROLE_PUSH_BUTTON);
    assert(ATK_IS_TEXT(field) && ATK_IS_EDITABLE_TEXT(field) && !ATK_IS_TEXT(button));
    gint x, y, width, height;
    atk_component_get_extents(ATK_COMPONENT(field), &x, &y, &width, &height, ATK_XY_PARENT);
    assert(x == 20 && y == 20 && width == 120 && height == 30);
    AtkObject *hit = atk_component_ref_accessible_at_point(ATK_COMPONENT(group), 35, 45, ATK_XY_WINDOW);
    assert(hit == field); g_object_unref(hit);
    assert(atk_text_get_character_count(ATK_TEXT(field)) == 3);
    assert(atk_text_get_character_at_offset(ATK_TEXT(field), 1) == 0x754c);
    assert(atk_text_get_caret_offset(ATK_TEXT(field)) == 2);
    gint start, end;
    char *selected = atk_text_get_selection(ATK_TEXT(field), 0, &start, &end);
    assert(start == 1 && end == 2 && strcmp(selected, "界") == 0); g_free(selected);
    assert(atk_text_set_selection(ATK_TEXT(field), 0, 2, 3));
    char changed[] = "copied";
    atk_editable_text_set_text_contents(ATK_EDITABLE_TEXT(field), changed);
    changed[0] = 'X';
    atk_editable_text_copy_text(ATK_EDITABLE_TEXT(field), 1, 2);
    atk_editable_text_cut_text(ATK_EDITABLE_TEXT(field), 1, 2);
    atk_editable_text_paste_text(ATK_EDITABLE_TEXT(field), 2);
    gint position = 1;
    atk_editable_text_insert_text(ATK_EDITABLE_TEXT(field), "é", 2, &position);
    assert(position == 2);
    assert(atk_action_do_action(ATK_ACTION(button), 0));
    fixture.refuse = true;
    telar_accessibility_dispatch(bridge);
    assert(fixture.count == 0 && bridge->action_count == 7);
    struct pollfd blocked = {.fd = telar_accessibility_fd(bridge), .events = POLLIN};
    assert(poll(&blocked, 1, 0) == 0);
    fixture.refuse = false;
    telar_accessibility_dispatch(bridge);
    assert(fixture.count == 7 && bridge->action_count == 0);
    assert(fixture.events[0].code == 8 && fixture.events[0].target_id == 2 && fixture.events[0].generation == 9);
    assert(fixture.events[0].selection_start == 4 && fixture.events[0].selection_end == 5);
    assert(strcmp(fixture.text[1], "copied") == 0);
    assert(fixture.events[2].code == 64 && fixture.events[2].selection_start == 1 && fixture.events[2].selection_end == 4);
    assert(fixture.events[3].code == 128 && fixture.events[4].code == 256 && fixture.events[4].selection_start == 4);
    assert(strcmp(fixture.text[5], "é") == 0 && fixture.events[5].code == 512);
    assert(fixture.events[5].revision == 42 && fixture.events[5].replacement_start == 1 && fixture.events[5].replacement_end == 1);
    for (unsigned i = 0; i < TELAR_ACCESSIBLE_ACTION_CAPACITY; i++) assert(atk_component_grab_focus(ATK_COMPONENT(field)));
    assert(!atk_component_grab_focus(ATK_COMPONENT(field)));
    telar_accessibility_dispatch(bridge);
    size_t previous_events = fixture.count;
    fixture.hold_after_capture = &bridge->lock;
    assert(atk_component_grab_focus(ATK_COMPONENT(field)));
    telar_accessibility_dispatch(bridge);
    assert(bridge->action_admitted && bridge->action_count == 1 && fixture.count == previous_events + 1);
    pthread_mutex_unlock(&bridge->lock);
    fixture.hold_after_capture = NULL;
    telar_accessibility_dispatch(bridge);
    assert(!bridge->action_admitted && bridge->action_count == 0 && fixture.count == previous_events + 1);
    telar_gui_accessibility_tree invalid = {.nodes = nodes, .count = 3};
    assert(valid_tree(&invalid));
    nodes[1].selection_start = 2;
    assert(!valid_tree(&invalid));
    nodes[1].selection_start = 1;
    g_object_ref(field);
    bridge->current.nodes[1].value.generation++;
    apply_snapshot(bridge);
    assert(bridge->objects[1] != field);
    AtkStateSet *state = atk_object_ref_state_set(field);
    assert(atk_state_set_contains_state(state, ATK_STATE_DEFUNCT)); g_object_unref(state);
    assert(!atk_component_grab_focus(ATK_COMPONENT(field)));
    g_object_unref(field);
    for (uint32_t i = 0; i < bridge->count; i++) g_signal_connect(bridge->objects[i], "state-change", G_CALLBACK(on_retired), bridge);
    bridge->current.count = 0;
    apply_snapshot(bridge);
    assert(retired_notifications == 3);
    telar_accessible_detach(bridge->root); g_object_unref(bridge->root);
    close(bridge->updates[0]); close(bridge->updates[1]); close(bridge->actions_wake[0]); close(bridge->actions_wake[1]);
    pthread_mutex_destroy(&bridge->lock);
    free(bridge);
}

static int serve(void) {
    struct fixture fixture = {.owner = pthread_self()};
    telar_gui_callbacks callbacks = {.input = capture, .accessibility = tree};
    telar_accessibility *bridge = telar_accessibility_create(&fixture, &callbacks);
    assert(bridge != NULL);
    telar_accessibility_update(bridge);
    time_t deadline = time(NULL) + 20;
    while (!fixture.finished && time(NULL) < deadline) {
        struct pollfd fd = {.fd = telar_accessibility_fd(bridge), .events = POLLIN};
        poll(&fd, 1, 100);
        telar_accessibility_dispatch(bridge);
        telar_accessibility_update(bridge);
    }
    telar_accessibility_destroy(bridge);
    assert(fixture.finished && fixture.count == 7);
    const uint32_t expected[] = {8, 4, 64, 128, 256, 2, 1};
    for (size_t i = 0; i < fixture.count; i++) {
        assert(fixture.events[i].kind == 10 && fixture.events[i].code == expected[i]);
        assert(fixture.events[i].target_id == (i == 6 ? 3u : 2u));
        assert(fixture.events[i].generation == (i == 6 ? 11u : 9u));
    }
    assert(fixture.events[0].selection_start == 1 && fixture.events[0].selection_end == 4);
    assert(strcmp(fixture.text[1], "新 name") == 0);
    assert(fixture.events[2].selection_start == 1 && fixture.events[2].selection_end == 4);
    assert(fixture.events[3].selection_start == 1 && fixture.events[3].selection_end == 4);
    assert(fixture.events[4].selection_start == 4 && fixture.events[4].selection_end == 4);
    puts("AT-SPI transport, UTF-8 ranges and window-thread actions passed");
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--serve") == 0) return serve();
    unit();
    return 0;
}

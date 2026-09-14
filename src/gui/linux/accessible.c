#define _POSIX_C_SOURCE 200809L
#include "accessibility_internal.h"
#include <limits.h>
#include <math.h>
#include <string.h>

typedef struct {
    AtkObject parent;
    telar_accessibility *owner;
    struct accessible_node node;
} TelarAccessible;
typedef AtkObjectClass TelarAccessibleClass;
typedef struct { TelarAccessible parent; } TelarTextAccessible;
typedef TelarAccessibleClass TelarTextAccessibleClass;

static void component_interface(AtkComponentIface *);
static void action_interface(AtkActionIface *);
static void text_interface(AtkTextIface *);
static void editable_interface(AtkEditableTextIface *);
static gint coordinate(double);

G_DEFINE_TYPE_WITH_CODE(TelarAccessible, telar_accessible, ATK_TYPE_OBJECT,
    G_IMPLEMENT_INTERFACE(ATK_TYPE_COMPONENT, component_interface)
    G_IMPLEMENT_INTERFACE(ATK_TYPE_ACTION, action_interface))
G_DEFINE_TYPE_WITH_CODE(TelarTextAccessible, telar_text_accessible, telar_accessible_get_type(),
    G_IMPLEMENT_INTERFACE(ATK_TYPE_TEXT, text_interface)
    G_IMPLEMENT_INTERFACE(ATK_TYPE_EDITABLE_TEXT, editable_interface))

static bool is_text_role(uint32_t role) { return role == 3 || role == 4 || role == 8; }
static TelarAccessible *accessible(gpointer object) { return (TelarAccessible *)object; }
static telar_gui_accessibility_node *value(gpointer object) { return &accessible(object)->node.value; }

bool telar_accessible_matches(AtkObject *object, const telar_gui_accessibility_node *node) {
    if (object == NULL) return false;
    const telar_gui_accessibility_node *current = value(object);
    return current->id == node->id && current->generation == node->generation && is_text_role(current->role) == is_text_role(node->role);
}

uint64_t telar_accessible_id(AtkObject *object) { return object == NULL ? 0 : value(object)->id; }

static AtkObject *parent_of(AtkObject *object) {
    TelarAccessible *self = accessible(object);
    return self->owner == NULL || self->node.value.id == 0 ? NULL : telar_accessibility_find(self->owner, self->node.value.parent_id);
}

static gint child_count(AtkObject *object) {
    TelarAccessible *self = accessible(object);
    if (self->owner == NULL) return 0;
    gint count = 0;
    for (uint32_t i = 0; i < self->owner->count; i++) {
        AtkObject *child = self->owner->objects[i];
        if (child != NULL && value(child)->parent_id == self->node.value.id) count++;
    }
    return count;
}

static AtkObject *child_at(AtkObject *object, gint index) {
    TelarAccessible *self = accessible(object);
    if (self->owner == NULL || index < 0) return NULL;
    for (uint32_t i = 0; i < self->owner->count; i++) {
        AtkObject *child = self->owner->objects[i];
        if (child != NULL && value(child)->parent_id == self->node.value.id && index-- == 0) return g_object_ref(child);
    }
    return NULL;
}

static gint index_in_parent(AtkObject *object) {
    TelarAccessible *self = accessible(object);
    if (self->owner == NULL || self->node.value.id == 0) return -1;
    gint index = 0;
    for (uint32_t i = 0; i < self->owner->count; i++) {
        AtkObject *candidate = self->owner->objects[i];
        if (candidate == object) return index;
        if (candidate != NULL && value(candidate)->parent_id == self->node.value.parent_id) index++;
    }
    return -1;
}

static AtkStateSet *states(AtkObject *object) {
    AtkStateSet *result = atk_state_set_new();
    TelarAccessible *self = accessible(object);
    if (self->owner == NULL) {
        atk_state_set_add_state(result, ATK_STATE_DEFUNCT);
        return result;
    }
    uint32_t flags = self->node.value.flags;
    atk_state_set_add_state(result, ATK_STATE_VISIBLE);
    atk_state_set_add_state(result, ATK_STATE_SHOWING);
    if (flags & 1) { atk_state_set_add_state(result, ATK_STATE_ENABLED); atk_state_set_add_state(result, ATK_STATE_SENSITIVE); }
    if (flags & 2) atk_state_set_add_state(result, ATK_STATE_FOCUSED);
    if (flags & 4) atk_state_set_add_state(result, ATK_STATE_SELECTED);
    if (flags & 8) atk_state_set_add_state(result, ATK_STATE_EDITABLE);
    if (flags & 16) atk_state_set_add_state(result, ATK_STATE_MULTI_LINE);
    if (flags & 32) atk_state_set_add_state(result, ATK_STATE_MODAL);
    if (self->node.value.actions & 2) atk_state_set_add_state(result, ATK_STATE_FOCUSABLE);
    if (self->node.value.role == 5 || self->node.value.role == 7) atk_state_set_add_state(result, ATK_STATE_SELECTABLE);
    return result;
}

static void telar_accessible_class_init(TelarAccessibleClass *class) {
    class->get_parent = parent_of;
    class->get_n_children = child_count;
    class->ref_child = child_at;
    class->get_index_in_parent = index_in_parent;
    class->ref_state_set = states;
}
static void telar_accessible_init(TelarAccessible *self) { (void)self; }
static void telar_text_accessible_class_init(TelarTextAccessibleClass *class) { (void)class; }
static void telar_text_accessible_init(TelarTextAccessible *self) { (void)self; }

static AtkRole role(uint32_t value) {
    switch (value) {
        case 2: return ATK_ROLE_PUSH_BUTTON;
        case 3: return ATK_ROLE_ENTRY;
        case 4: return ATK_ROLE_LABEL;
        case 5: return ATK_ROLE_PAGE_TAB;
        case 6: return ATK_ROLE_LIST;
        case 7: return ATK_ROLE_LIST_ITEM;
        case 8: return ATK_ROLE_TERMINAL;
        default: return ATK_ROLE_PANEL;
    }
}

void telar_accessible_update(AtkObject *object, const telar_gui_accessibility_node *node) {
    TelarAccessible *self = accessible(object);
    uint32_t old_flags = self->node.value.flags;
    bool text_changed = self->node.value.value_len != node->value_len || (node->value_len != 0 && memcmp(self->node.text, node->value, node->value_len) != 0);
    bool selection_changed = self->node.value.selection_start != node->selection_start || self->node.value.selection_end != node->selection_end;
    gint old_chars = (gint)g_utf8_strlen(self->node.text, -1);
    if (text_changed && old_chars != 0 && ATK_IS_TEXT(object)) g_signal_emit_by_name(object, "text-changed::delete", 0, old_chars);
    self->node.value = *node;
    if (node->label_len != 0) memcpy(self->node.label, node->label, node->label_len);
    self->node.label[node->label_len] = 0;
    if (node->value_len != 0) memcpy(self->node.text, node->value, node->value_len);
    self->node.text[node->value_len] = 0;
    self->node.value.label = (const uint8_t *)self->node.label;
    self->node.value.value = (const uint8_t *)self->node.text;
    atk_object_set_name(object, self->node.label);
    atk_object_set_role(object, role(node->role));
    const AtkStateType types[] = {ATK_STATE_ENABLED, ATK_STATE_FOCUSED, ATK_STATE_SELECTED, ATK_STATE_EDITABLE, ATK_STATE_MULTI_LINE, ATK_STATE_MODAL};
    for (unsigned i = 0; i < 6; i++) {
        if ((old_flags ^ node->flags) & (1u << i)) atk_object_notify_state_change(object, types[i], (node->flags & (1u << i)) != 0);
    }
    if (text_changed && ATK_IS_TEXT(object)) g_signal_emit_by_name(object, "text-changed::insert", 0, (gint)g_utf8_strlen(self->node.text, -1));
    if (selection_changed && ATK_IS_TEXT(object)) {
        g_signal_emit_by_name(object, "text-caret-moved", (gint)g_utf8_pointer_to_offset(self->node.text, self->node.text + node->selection_end));
        g_signal_emit_by_name(object, "text-selection-changed");
    }
    AtkRectangle bounds = {coordinate(node->x), coordinate(node->y), coordinate(node->width), coordinate(node->height)};
    g_signal_emit_by_name(object, "bounds-changed", &bounds);
}

AtkObject *telar_accessible_new(telar_accessibility *owner, const telar_gui_accessibility_node *node) {
    TelarAccessible *self = g_object_new(node != NULL && is_text_role(node->role) ? telar_text_accessible_get_type() : telar_accessible_get_type(), NULL);
    self->owner = owner;
    if (node != NULL) telar_accessible_update(ATK_OBJECT(self), node);
    else {
        self->node.value.flags = 1;
        atk_object_set_name(ATK_OBJECT(self), "Telar");
        atk_object_set_role(ATK_OBJECT(self), ATK_ROLE_APPLICATION);
    }
    return ATK_OBJECT(self);
}

void telar_accessible_detach(AtkObject *object) {
    accessible(object)->owner = NULL;
    atk_object_notify_state_change(object, ATK_STATE_DEFUNCT, TRUE);
}

static bool request(TelarAccessible *self, telar_gui_input event) {
    if (self->owner == NULL || !(self->node.value.flags & 1) || !(self->node.value.actions & event.code)) return false;
    event.kind = 10;
    event.target_id = self->node.value.id;
    event.generation = self->node.value.generation;
    event.revision = self->node.value.text_revision;
    return telar_accessibility_enqueue(self->owner, event);
}

static gint coordinate(double value) { return (gint)fmax(G_MININT, fmin(G_MAXINT, floor(value))); }
static void extents(AtkComponent *component, gint *x, gint *y, gint *width, gint *height, AtkCoordType coords) {
    TelarAccessible *self = accessible(component);
    telar_gui_accessibility_node *node = &self->node.value;
    double left = node->x, top = node->y;
    if (coords == ATK_XY_PARENT) {
        AtkObject *parent = parent_of(ATK_OBJECT(self));
        if (parent != NULL) { left -= value(parent)->x; top -= value(parent)->y; }
    }
    // Wayland does not disclose a toplevel's global desktop position.
    *x = coords == ATK_XY_SCREEN || self->owner == NULL ? G_MININT : coordinate(left);
    *y = coords == ATK_XY_SCREEN || self->owner == NULL ? G_MININT : coordinate(top);
    *width = coordinate(node->width);
    *height = coordinate(node->height);
}

static gboolean contains(AtkComponent *component, gint x, gint y, AtkCoordType coords) {
    if (coords == ATK_XY_SCREEN || accessible(component)->owner == NULL) return FALSE;
    gint left, top, width, height;
    extents(component, &left, &top, &width, &height, coords);
    return (double)x >= left && (double)y >= top && (double)x < (double)left + width && (double)y < (double)top + height;
}

static AtkObject *at_point(AtkComponent *component, gint x, gint y, AtkCoordType coords) {
    if (coords == ATK_XY_SCREEN) return NULL;
    if (coords == ATK_XY_PARENT) {
        AtkObject *parent = parent_of(ATK_OBJECT(component));
        if (parent != NULL) { x = coordinate((double)x + value(parent)->x); y = coordinate((double)y + value(parent)->y); }
    }
    gint count = child_count(ATK_OBJECT(component));
    for (gint i = count - 1; i >= 0; i--) {
        AtkObject *child = child_at(ATK_OBJECT(component), i);
        if (contains(ATK_COMPONENT(child), x, y, ATK_XY_WINDOW)) return child;
        g_object_unref(child);
    }
    return NULL;
}
static gboolean grab_focus(AtkComponent *component) { return request(accessible(component), (telar_gui_input){.code = 2}); }
static AtkLayer layer(AtkComponent *component) { (void)component; return ATK_LAYER_WIDGET; }
static void component_interface(AtkComponentIface *interface) {
    interface->get_extents = extents;
    interface->contains = contains;
    interface->ref_accessible_at_point = at_point;
    interface->grab_focus = grab_focus;
    interface->get_layer = layer;
}

static uint32_t action_at(AtkAction *object, gint index) {
    uint32_t actions = value(object)->actions & ~(4u | 8u);
    if (index < 0 || accessible(object)->owner == NULL) return 0;
    for (unsigned bit = 0; bit < 6; bit++) {
        if ((actions & (1u << bit)) && index-- == 0) return 1u << bit;
    }
    return 0;
}
static gint action_count(AtkAction *object) {
    gint count = 0;
    while (action_at(object, count) != 0) count++;
    return count;
}
static const gchar *action_name(AtkAction *object, gint index) {
    switch (action_at(object, index)) {
        case 1: return "press";
        case 2: return "focus";
        case 4: return "set-value";
        case 8: return "set-selection";
        case 16: return "increment";
        case 32: return "decrement";
        default: return NULL;
    }
}
static gboolean do_action(AtkAction *object, gint index) {
    uint32_t action = action_at(object, index);
    return action != 0 && action != 4 && action != 8 && request(accessible(object), (telar_gui_input){.code = action});
}
static void action_interface(AtkActionIface *interface) {
    interface->get_n_actions = action_count;
    interface->get_name = action_name;
    interface->get_localized_name = action_name;
    interface->do_action = do_action;
}

static const char *text_value(AtkText *object) {
    TelarAccessible *self = accessible(object);
    return self->node.value.role == 4 && self->node.value.value_len == 0 ? self->node.label : self->node.text;
}
static gint text_count(AtkText *object) { return (gint)g_utf8_strlen(text_value(object), -1); }
static const char *text_position(AtkText *object, gint offset) {
    return offset < 0 || offset > text_count(object) ? NULL : g_utf8_offset_to_pointer(text_value(object), offset);
}
static gchar *get_text(AtkText *object, gint start, gint end) {
    if (end == -1) end = text_count(object);
    const char *begin = text_position(object, start), *finish = text_position(object, end);
    return begin == NULL || finish == NULL || end < start ? NULL : g_strndup(begin, (gsize)(finish - begin));
}
static gunichar character(AtkText *object, gint offset) {
    const char *position = text_position(object, offset);
    return position == NULL ? 0 : g_utf8_get_char(position);
}
static gint caret(AtkText *object) { return (gint)g_utf8_pointer_to_offset(text_value(object), text_value(object) + value(object)->selection_end); }
static gint selection_count(AtkText *object) { return value(object)->selection_start == value(object)->selection_end ? 0 : 1; }
static gchar *selection_text(AtkText *object, gint index, gint *start, gint *end) {
    if (index != 0 || selection_count(object) == 0) return NULL;
    const char *text = text_value(object);
    uint32_t a = value(object)->selection_start, b = value(object)->selection_end;
    *start = (gint)g_utf8_pointer_to_offset(text, text + (a < b ? a : b));
    *end = (gint)g_utf8_pointer_to_offset(text, text + (a > b ? a : b));
    return get_text(object, *start, *end);
}
static gboolean set_selection(AtkText *object, gint index, gint start, gint end) {
    if (index != 0) return FALSE;
    const char *begin = text_position(object, start), *finish = text_position(object, end), *text = text_value(object);
    if (begin == NULL || finish == NULL) return FALSE;
    return request(accessible(object), (telar_gui_input){.code = 8, .selection_start = (uint32_t)(begin - text), .selection_end = (uint32_t)(finish - text)});
}
static gboolean add_selection(AtkText *object, gint start, gint end) { return set_selection(object, 0, start, end); }
static gboolean set_caret(AtkText *object, gint offset) { return set_selection(object, 0, offset, offset); }
static gboolean remove_selection(AtkText *object, gint index) { return index == 0 && set_caret(object, caret(object)); }

static gchar *string_at(AtkText *object, gint offset, AtkTextGranularity granularity, gint *start, gint *end) {
    gint count = text_count(object);
    if (offset < 0 || offset >= count) return NULL;
    *start = offset;
    *end = offset + 1;
    if (granularity == ATK_TEXT_GRANULARITY_WORD) {
        while (*start > 0 && !g_unichar_isspace(character(object, *start - 1))) (*start)--;
        while (*end < count && !g_unichar_isspace(character(object, *end))) (*end)++;
    } else if (granularity == ATK_TEXT_GRANULARITY_LINE || granularity == ATK_TEXT_GRANULARITY_PARAGRAPH) {
        while (*start > 0 && character(object, *start - 1) != '\n') (*start)--;
        while (*end < count && character(object, *end - 1) != '\n') (*end)++;
    } else if (granularity != ATK_TEXT_GRANULARITY_CHAR) {
        return NULL;
    }
    return get_text(object, *start, *end);
}
static void text_interface(AtkTextIface *interface) {
    interface->get_text = get_text;
    interface->get_character_count = text_count;
    interface->get_character_at_offset = character;
    interface->get_caret_offset = caret;
    interface->get_n_selections = selection_count;
    interface->get_selection = selection_text;
    interface->set_selection = set_selection;
    interface->add_selection = add_selection;
    interface->remove_selection = remove_selection;
    interface->set_caret_offset = set_caret;
    interface->get_string_at_offset = string_at;
}

static void set_contents(AtkEditableText *object, const gchar *text) {
    if (text == NULL) return;
    size_t len = strnlen(text, TELAR_GUI_TEXT_CAPACITY + 1);
    if (len <= TELAR_GUI_TEXT_CAPACITY) request(accessible(object), (telar_gui_input){.code = 4, .text = (const uint8_t *)text, .len = len});
}
static bool replace_range(AtkEditableText *object, gint start, gint end, const gchar *inserted, gint len) {
    const char *text = text_value(ATK_TEXT(object));
    const char *begin = text_position(ATK_TEXT(object), start), *finish = text_position(ATK_TEXT(object), end);
    if (begin == NULL || finish == NULL || end < start || len < 0 || (size_t)len > TELAR_GUI_TEXT_CAPACITY) return false;
    return request(accessible(object), (telar_gui_input){.code = 512, .text = (const uint8_t *)inserted, .len = (size_t)len,
        .replacement_start = (uint32_t)(begin - text), .replacement_end = (uint32_t)(finish - text)});
}
static void insert_text(AtkEditableText *object, const gchar *text, gint length, gint *position) {
    if (text == NULL || position == NULL || length < 0 || !g_utf8_validate(text, length, NULL)) return;
    if (replace_range(object, *position, *position, text, length)) *position += (gint)g_utf8_strlen(text, length);
}
static void delete_text(AtkEditableText *object, gint start, gint end) { replace_range(object, start, end, "", 0); }
static void clipboard_range(AtkEditableText *object, uint32_t action, gint start, gint end) {
    AtkText *text_object = ATK_TEXT(object);
    const char *text = text_value(text_object), *begin = text_position(text_object, start), *finish = text_position(text_object, end);
    if (begin == NULL || finish == NULL || start > end) return;
    request(accessible(object), (telar_gui_input){.code = action, .selection_start = (uint32_t)(begin - text), .selection_end = (uint32_t)(finish - text)});
}
static void copy_text(AtkEditableText *object, gint start, gint end) { clipboard_range(object, 64, start, end); }
static void cut_text(AtkEditableText *object, gint start, gint end) { clipboard_range(object, 128, start, end); }
static void paste_text(AtkEditableText *object, gint position) { clipboard_range(object, 256, position, position); }
static void editable_interface(AtkEditableTextIface *interface) {
    interface->set_text_contents = set_contents;
    interface->insert_text = insert_text;
    interface->delete_text = delete_text;
    interface->copy_text = copy_text;
    interface->cut_text = cut_text;
    interface->paste_text = paste_text;
}

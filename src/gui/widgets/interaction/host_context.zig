//! Synchronous semantic snapshots. Native adapters copy borrowed bytes before
//! returning; only their platform caches persist beyond this call. Focus is
//! already reconciled: `GuiAdapter.update` does it after every turn.
const EditorDisplay = @import("EditorDisplay.zig");
const GuiAdapter = @import("../../GuiAdapter.zig");
const native = @import("../../native/native.zig");
const FieldView = @import("FieldView.zig");
const std = @import("std");
const core = @import("telar-core");
const event = @import("../../input/event.zig");

comptime {
    // The native IME and accessibility values take a whole field, up to
    // `TELAR_GUI_TEXT_CAPACITY` (mirrored by `max_composition_bytes`); a
    // longer field would turn input methods off for it.
    std.debug.assert(core.max_cwd_bytes <= event.max_composition_bytes);
    std.debug.assert(core.max_tab_label_bytes <= event.max_composition_bytes);
}

/// Uses current committed text and the delivered editor's geometry. Preedit
/// is intentionally excluded from surrounding text sent to the native IME.
/// Example: `if (host_context.text(gui, output)) publish(output);`
pub fn text(gui: *GuiAdapter, output: *native.TextContext) bool {
    output.* = .{};
    if (!gui.focused) {
        return false;
    }

    const target = gui.widgets.dispatcher.focusedTarget() orelse return false;
    const current = FieldView.captureClient(gui.app, target) orelse return false;
    const geometry = gui.widgets.editors.presented().find(target.id) orelse return false;
    const preedit = if (gui.widgets.preedit.owner) |owner| if (owner.eql(target.id)) &gui.widgets.preedit else null else null;
    var display = EditorDisplay.capture(current, preedit);
    const view = display.field.view(geometry.columns);
    output.* = .{
        .target_id = target.id.target_id,
        .generation = target.id.generation,
        .revision = FieldView.revision(gui.app) +% gui.widgets.dispatcher.revision,
        .enabled = 1,
        .composition_active = @intFromBool(preedit != null),
        .text = current.text.ptr,
        .len = current.text.len,
        .selection_start = current.anchor,
        .selection_end = current.head,
        .x = geometry.bounds.x + @as(f64, @floatFromInt(@min(view.cursor, geometry.columns -| 1))) * geometry.cell_width,
        .y = geometry.bounds.y,
        .width = 1,
        .height = geometry.bounds.height,
    };
    return true;
}

/// Every node uses delivered bounds and copied labels. Editable values borrow
/// the current matching prompt only until the host copies this snapshot.
/// Example: `if (host_context.accessibility(gui, output)) publish(output);`
pub fn accessibility(gui: *GuiAdapter, output: *native.AccessibilityTree) bool {
    const state = &gui.widgets;
    const registry = state.dispatcher.maps.presented();
    const modal = gui.app.model.name_prompt.active();
    var count: usize = 0;
    state.accessibility_dropped = 0;
    for (registry.targets[0..registry.len]) |*target| {
        if (target.layer < registry.modal_layer or (target.layer != 0) != modal) {
            continue;
        }

        const focused = if (state.dispatcher.focused) |id| id.eql(target.id) else false;
        // A full tree still publishes the focused control, in place of the
        // last node it holds.
        var slot = count;
        if (count == state.native_nodes.len) {
            if (!focused) {
                state.accessibility_dropped += 1;
                continue;
            }

            slot = count - 1;
            state.accessibility_dropped += 1;
        }
        var node: native.AccessibilityNode = .{
            .id = target.id.target_id,
            .generation = target.id.generation,
            .role = target.role,
            .flags = @as(u32, @intFromBool(target.enabled)) | (if (focused) @as(u32, 2) else 0) | (if (target.layer != 0) @as(u32, 32) else 0),
            .actions = (if (target.focusable) @as(u32, 2) else 0) | (if (target.activatable()) @as(u32, 1) else 0),
            .x = target.bounds.x,
            .y = target.bounds.y,
            .width = target.bounds.width,
            .height = target.bounds.height,
            .label = &target.label,
            .label_len = target.label_len,
        };
        if (target.action == .text_field) {
            const current = FieldView.captureClient(gui.app, target.*) orelse continue;
            node.flags |= 8;
            node.actions |= 4 | 8 | 64 | 128 | 256 | 512;
            node.text_revision = FieldView.revision(gui.app);
            node.value = current.text.ptr;
            node.value_len = current.text.len;
            node.selection_start = current.anchor;
            node.selection_end = current.head;
        }

        state.native_nodes[slot] = node;
        count = slot + 1;
    }

    output.* = .{ .revision = gui.chrome.revision +% gui.app.model.name_prompt.version() +% gui.app.model.version().panes +% state.dispatcher.revision, .nodes = &state.native_nodes, .count = @intCast(count) };
    return count != 0;
}

//! Synchronous semantic snapshots. Native adapters copy borrowed bytes before
//! returning; only their platform caches persist beyond this call.
const std = @import("std");
const client = @import("telar-client");
const GuiClient = @import("../../GuiClient.zig");
const native = @import("../../native/native.zig");
const FieldView = @import("FieldView.zig");
const GenericField = client.GenericField;

/// Uses current committed text and the delivered editor's geometry. Preedit
/// is intentionally excluded from surrounding text sent to the native IME.
/// Example: `if (host_context.text(gui, output)) publish(output);`
pub fn text(gui: *GuiClient, output: *native.TextContext) bool {
    output.* = .{};
    if (!gui.focused) {
        return false;
    }

    const target = gui.widgets.dispatcher.focusedTarget() orelse return false;
    const prompt = gui.app.model.name_prompt.currentConst() orelse return false;
    const current = FieldView.capture(prompt, target) orelse return false;
    const geometry = gui.widgets.editors.presented().find(target.id) orelse return false;
    const preedit = if (gui.widgets.preedit.owner) |owner| if (owner.eql(target.id)) &gui.widgets.preedit else null else null;
    var display = @import("EditorDisplay.zig").capture(current, preedit);
    const view = display.field.view(geometry.columns);
    output.* = .{
        .target_id = target.id.target_id,
        .generation = target.id.generation,
        .revision = gui.app.model.name_prompt.version() +% gui.widgets.dispatcher.revision,
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
pub fn accessibility(gui: *GuiClient, output: *native.AccessibilityTree) bool {
    const state = &gui.widgets;
    const registry = state.dispatcher.maps.presented();
    const modal = gui.app.model.name_prompt.active();
    var count: usize = 0;
    for (registry.targets[0..registry.len]) |*target| {
        if (target.layer < registry.modal_layer or (target.layer != 0) != modal) {
            continue;
        }

        const focused = if (state.dispatcher.focused) |id| id.eql(target.id) else false;
        var node: native.AccessibilityNode = .{
            .id = target.id.target_id,
            .generation = target.id.generation,
            .role = target.role,
            .flags = @as(u32, @intFromBool(target.enabled)) | (if (focused) @as(u32, 2) else 0) | (if (target.layer != 0) @as(u32, 32) else 0),
            .actions = (if (target.focusable) @as(u32, 2) else 0) | (if (target.action == .intent) @as(u32, 1) else 0),
            .x = target.bounds.x,
            .y = target.bounds.y,
            .width = target.bounds.width,
            .height = target.bounds.height,
            .label = &target.label,
            .label_len = target.label_len,
        };
        if (target.action == .text_field) {
            const prompt = gui.app.model.name_prompt.currentConst() orelse continue;
            const current = FieldView.capture(prompt, target.*) orelse continue;
            node.flags |= 8;
            node.actions |= 4 | 8 | 64 | 128 | 256 | 512;
            node.text_revision = gui.app.model.name_prompt.version();
            node.value = current.text.ptr;
            node.value_len = current.text.len;
            node.selection_start = current.anchor;
            node.selection_end = current.head;
        }

        state.native_nodes[count] = node;
        count += 1;
    }

    output.* = .{ .revision = gui.chrome.revision +% gui.app.model.name_prompt.version() +% state.dispatcher.revision, .nodes = &state.native_nodes, .count = @intCast(count) };
    return count != 0;
}

//! Synchronous semantic snapshots. Native adapters copy borrowed bytes before
//! returning; only their platform caches persist beyond this call. Focus is
//! already reconciled: `GuiAdapter.loop` does it after every turn.

const Window = @import("telar-window");
const EditorDisplay = @import("EditorDisplay.zig");
const WindowModel = @import("../../WindowModel.zig");
const native = @import("../../native/native.zig");
const FieldView = @import("FieldView.zig");
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const event = Window;

comptime {
    // The native IME and accessibility values take a whole field, up to
    // `TELAR_GUI_TEXT_CAPACITY` (mirrored by `max_composition_bytes`); a
    // longer field would turn input methods off for it.
    std.debug.assert(core.max_cwd_bytes <= event.Input.max_composition_bytes);
    std.debug.assert(core.max_tab_label_bytes <= event.Input.max_composition_bytes);
}

/// Uses current committed text and the delivered editor's geometry. Preedit
/// is intentionally excluded from surrounding text sent to the native IME.
/// Example: `if (host_context.text(gui, output)) publish(output);`
pub fn text(model: *WindowModel, app: *client.Client, output: *native.TextContext) bool {
    output.* = .{};
    if (!model.focused) {
        return false;
    }

    const target = model.widgets.dispatcher.focusedTarget() orelse return false;
    const current = FieldView.captureClient(app, target) orelse return false;
    const geometry = model.widgets.editors.presented().find(target.id) orelse return false;
    const preedit = if (model.widgets.preedit.owner) |owner| if (owner.eql(target.id)) &model.widgets.preedit else null else null;
    var display = EditorDisplay.capture(current, preedit);
    const view = display.field.view(geometry.columns);
    output.* = .{
        .target_id = target.id.target_id,
        .generation = target.id.generation,
        .revision = FieldView.revision(app) +% model.widgets.dispatcher.revision,
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

//! Wires copy-mode pointer ownership to geometry and copy-mode effects.

const core = @import("telar-core");
const presentation = @import("../../../presentation/root.zig");
const workspace_capability = @import("../../../workspace/root.zig");
const input_application = @import("telar-client").application.input;
const copy_modes = @import("copy_modes.zig");

const Client = @import("../../Client.zig");
const copy_mode_pointer = input_application.copy_mode_pointer;
pub const multiplexer = workspace_capability.multiplexer;
const term = presentation.screen;
pub const ui = core.ui;

const Context = @import("CopyModePointerContext.zig");

/// Gives copy mode first refusal for one cell-based pointer event.
///
/// ```zig
/// if (try apply(client, model, event)) return;
/// ```
pub fn apply(client: *Client, model: *multiplexer.Model, event: term.Event.Mouse) !bool {
    var context: Context = .{
        .client = client,
        .model = model,
        .area = client.geometry().area,
    };

    var use_case: copy_mode_pointer.CopyModePointerHandler = .{
        .effects = .{
            .context = &context,
            .leave = leave,
            .vertical = vertical,
            .pointer = pointer,
            .cancel_pointer = cancelPointer,
        },
    };

    const outcome = try use_case.execute(.{
        .kind = event.kind,
        .left_button = event.button & 0b11 == 0,
    }, resolve(&context, event));

    return outcome != .unowned;
}

fn resolve(context: *Context, event: term.Event.Mouse) copy_mode_pointer.Authority {
    if (context.client.model.pointerSelection()) |selection| {
        const view = context.model.viewForPane(selection.pane_id, context.area);
        const position: ?ui.Point = if (view != null and view.?.content.w > 0 and view.?.content.h > 0) .{
            .x = @min(event.x -| view.?.content.x, view.?.content.w - 1),
            .y = @min(event.y -| view.?.content.y, view.?.content.h - 1),
        } else null;

        return .{ .selection = .{ .dragging = selection.dragging, .position = position } };
    }

    const pane_id = context.client.model.copyModeTarget() orelse return .unowned;
    if (context.model.find(pane_id) == null) {
        return .target_missing;
    }

    const view = context.model.viewForPane(pane_id, context.area) orelse
        return .{ .owned = .{ .pointer_inside = false } };

    return .{ .owned = .{
        .pointer_inside = view.content.contains(event.x, event.y),
    } };
}

fn leave(raw_context: *anyopaque) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.leave(context.client);
}

fn cancelPointer(raw_context: *anyopaque) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.cancelPointer(context.client);
}

fn pointer(raw_context: *anyopaque, motion: @import("telar-client").input.copy_mode.PointerMotion) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.pointer(context.client, motion);
}

fn vertical(raw_context: *anyopaque, delta: i32) !void {
    const context: *Context = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.vertical(context.client, delta);
}

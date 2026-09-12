//! Wires copy-mode pointer ownership to geometry and copy-mode effects.

const Client = @import("../../AttachedClient.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const MouseType = @import("../../input/Mouse.zig");
const CopyModePointerContext = @import("CopyModePointerContext.zig");
const CopyModePointerHandlerType = @import("../../application/input/CopyModePointerHandler.zig");
const ApplicationInputCopyModePointerAuthority = @import("../../application/input/copy_mode_pointer.zig").Authority;
const PointType = @import("telar-core").Point;
const copy_modes = @import("copy_modes.zig");
const PointerMotionType = @import("../../input/PointerMotion.zig");

/// Gives copy mode first refusal for one cell-based pointer event.
///
/// ```zig
/// if (try apply(client, model, event)) return;
/// ```
pub fn apply(client: *Client, model: *MultiplexerModel, event: MouseType) !bool {
    var context: CopyModePointerContext = .{
        .client = client,
        .model = model,
        .area = client.geometry().area,
    };

    var use_case: CopyModePointerHandlerType = .{
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

fn resolve(context: *CopyModePointerContext, event: MouseType) ApplicationInputCopyModePointerAuthority {
    if (context.client.model.pointerSelection()) |selection| {
        const view = context.model.viewForPane(selection.pane_id, context.area);
        const position: ?PointType = if (view != null and view.?.content.w > 0 and view.?.content.h > 0) .{
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
    const context: *CopyModePointerContext = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.leave(context.client);
}

fn cancelPointer(raw_context: *anyopaque) !void {
    const context: *CopyModePointerContext = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.cancelPointer(context.client);
}

fn pointer(raw_context: *anyopaque, motion: PointerMotionType) !void {
    const context: *CopyModePointerContext = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.pointer(context.client, motion);
}

fn vertical(raw_context: *anyopaque, delta: i32) !void {
    const context: *CopyModePointerContext = @ptrCast(@alignCast(raw_context));

    _ = try copy_modes.vertical(context.client, delta);
}

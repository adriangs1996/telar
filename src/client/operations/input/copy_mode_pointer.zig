//! Wires copy-mode pointer ownership to geometry and copy-mode effects.

const CopyModePointerCommand = @import("../../application/input/CopyModePointerCommand.zig");
const copy_mode_pointer = @import("../../application/input/copy_mode_pointer.zig");
const Client = @import("../../AttachedClient.zig");
const MultiplexerModel = @import("../../workspace/MultiplexerModel.zig");
const MouseType = @import("../../input/Mouse.zig");
const CopyModePointerContext = @import("CopyModePointerContext.zig");
const ApplicationInputCopyModePointerAuthority = @import("../../application/input/copy_mode_pointer.zig").Authority;
const PointType = @import("telar-core").Point;
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

    const command: CopyModePointerCommand = .{ .kind = event.kind, .left_button = event.button & 0b11 == 0 };
    const outcome = try route(&context, command, resolve(&context, event));
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

fn leave(context: *CopyModePointerContext) !void {
    _ = try context.client.leaveCopyMode();
}

fn cancelPointer(context: *CopyModePointerContext) !void {
    _ = try context.client.applyCopyMode(.cancel_pointer);
}

fn pointer(context: *CopyModePointerContext, motion: PointerMotionType) !void {
    _ = try context.client.applyCopyMode(
        .{
            .pointer = motion,
        },
    );
}

fn vertical(context: *CopyModePointerContext, delta: i32) !void {
    _ = try context.client.applyCopyMode(
        .{
            .vertical = delta,
        },
    );
}

fn route(context: *CopyModePointerContext, command: CopyModePointerCommand, authority: copy_mode_pointer.Authority) !copy_mode_pointer.Outcome {
    const pointer_inside = switch (authority) {
        .unowned => return .unowned,
        .target_missing => {
            try leave(context);

            return .exited;
        },
        .selection => |selection| {
            if (selection.dragging and command.kind == .press and command.left_button) {
                try cancelPointer(context);

                return .unowned;
            }

            if (!selection.dragging) {
                if (command.kind == .press or command.kind == .scroll_up or command.kind == .scroll_down) {
                    try cancelPointer(context);
                }

                return .unowned;
            }

            if (!command.left_button or (command.kind != .drag and command.kind != .release)) {
                return .consumed;
            }

            const position = selection.position orelse {
                if (command.kind == .release) {
                    try cancelPointer(context);
                }

                return .consumed;
            };
            try pointer(context, .{
                .position = position,
                .release = command.kind == .release,
            });
            return .moved;
        },
        .owned => |owned| owned.pointer_inside,
    };

    const delta: i32 = switch (command.kind) {
        .scroll_up => -3,
        .scroll_down => 3,
        else => return .consumed,
    };

    if (!pointer_inside) {
        return .consumed;
    }

    try vertical(context, delta);
    return .moved;
}

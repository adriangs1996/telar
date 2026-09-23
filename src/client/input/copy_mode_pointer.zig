//! Gives copy mode first refusal for pointer events inside its pane.

const data = @import("model");
const core = @import("telar-core");
const Client = @import("../execution/Client.zig");
const copy_mode = @import("copy_mode.zig");

/// Gives copy mode first refusal for one cell-based pointer event on tab
/// `tab`, and reports whether copy mode took it.
///
/// ```zig
/// if (try apply(client, tab, event)) return;
/// ```
pub fn apply(client: *Client, tab: usize, event: data.Mouse) !bool {
    const command: CopyModePointerCommand = .{ .kind = event.kind, .left_button = event.button & 0b11 == 0 };
    const outcome = try route(client, command, resolve(&client.model, tab, event));
    return outcome != .unowned;
}

fn resolve(model: *data.ClientModel, tab: usize, event: data.Mouse) Authority {
    const area = data.workbench.region(model).area;
    if (model.pointerSelection()) |selection| {
        const view = data.tab_layout.view(model, tab, selection.pane_id, area);
        const position: ?core.Point = if (view != null and view.?.content.w > 0 and view.?.content.h > 0) .{
            .x = @min(event.x -| view.?.content.x, view.?.content.w - 1),
            .y = @min(event.y -| view.?.content.y, view.?.content.h - 1),
        } else null;

        return .{ .selection = .{ .dragging = selection.dragging, .position = position } };
    }

    const pane_id = model.copyModeTarget() orelse return .unowned;
    if (model.panes.findIn(model.tabs.location[tab].tab_id, pane_id) == null) {
        return .target_missing;
    }

    const view = data.tab_layout.view(model, tab, pane_id, area) orelse
        return .{ .owned = .{ .pointer_inside = false } };

    return .{ .owned = .{
        .pointer_inside = view.content.contains(event.x, event.y),
    } };
}

fn route(client: *Client, command: CopyModePointerCommand, authority: Authority) !Outcome {
    const pointer_inside = switch (authority) {
        .unowned => return .unowned,
        .target_missing => {
            _ = try copy_mode.leaveCopyMode(client);
            return .exited;
        },
        .selection => |selection| {
            if (selection.dragging and command.kind == .press and command.left_button) {
                _ = try copy_mode.applyCopyMode(client, .cancel_pointer);
                return .unowned;
            }

            if (!selection.dragging) {
                if (command.kind == .press or command.kind == .scroll_up or command.kind == .scroll_down) {
                    _ = try copy_mode.applyCopyMode(client, .cancel_pointer);
                }

                return .unowned;
            }

            if (!command.left_button or (command.kind != .drag and command.kind != .release)) {
                return .consumed;
            }

            const position = selection.position orelse {
                if (command.kind == .release) {
                    _ = try copy_mode.applyCopyMode(client, .cancel_pointer);
                }

                return .consumed;
            };
            _ = try copy_mode.applyCopyMode(client, .{
                .pointer = .{
                    .position = position,
                    .release = command.kind == .release,
                },
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

    _ = try copy_mode.applyCopyMode(client, .{
        .vertical = delta,
    });
    return .moved;
}

pub const Authority = union(enum) {
    unowned,
    target_missing,
    selection: struct {
        dragging: bool,
        position: ?core.Point,
    },
    owned: struct {
        pointer_inside: bool,
    },
};

pub const Outcome = enum {
    unowned,
    consumed,
    moved,
    exited,
};

const CopyModePointerCommand = struct {
    kind: data.Mouse.Kind,
    left_button: bool = true,
};

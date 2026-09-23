//! Tab move: reorders a tab and adopts the runtime's confirmed position.
const data = @import("model");
const core = @import("telar-core");
const std = @import("std");
const runtime_io = @import("../connection/runtime_io.zig");

/// Validates one request and retains its correlation before delivery.
/// Example: `_ = try tab_move.requestTabMove(client, command);`
pub fn requestTabMove(model: *data.ClientModel, command: data.RequestTabMove) !bool {
    if (model.request_lifecycle.tracker.has(.tab_operation)) {
        return false;
    }

    const location = command.location orelse model.activeTabLocation() orelse return false;
    const workspace = model.workspace orelse return false;
    if (!std.meta.eql(workspace, location.workspace) or model.tabs.find(location.tab_id) == null) {
        return false;
    }

    if (command.relative_to) |anchor| {
        if (anchor == location.tab_id or model.tabs.find(anchor) == null) {
            return false;
        }
    }

    const request_id = try model.request_lifecycle.nextId();
    try runtime_io.sendRuntimeRequest(
        model,
        .{
            .registration = .{
                .request_id = request_id,
                .continuation = .{
                    .move_tab = location,
                },
            },
            .message = .{
                .move_tab = .{
                    .request_id = request_id,
                    .location = location,
                    .direction = command.direction,
                    .relative_to = command.relative_to,
                },
            },
        },
    );

    return true;
}

/// Consumes one correlated runtime completion before committing canonical state.
pub fn completeTabMove(model: *data.ClientModel, moved: core.TabMoved) !data.Change {
    const continuation = model.request_lifecycle.tracker.take(moved.request_id) orelse
        return error.UnexpectedTabMoved;
    const expected_location = switch (continuation) {
        .move_tab => |location| location,
        else => return error.UnexpectedTabMoved,
    };

    if (!std.meta.eql(expected_location, moved.location)) {
        return error.UnexpectedTabMoved;
    }

    return model.applyTabPosition(moved.location, moved.position) catch return error.UnexpectedTabMoved;
}

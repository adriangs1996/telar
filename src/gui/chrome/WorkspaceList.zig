const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Context = @import("Context.zig");
const Strip = @import("Strip.zig");
const WorkspaceList = @This();

context: *Context,
area: core.Rect,

/// Resolves active names from the client before the runtime list catches up.
/// Example: `try list.paint();`
pub fn paint(list: WorkspaceList) !void {
    const projection = list.context.projection;
    if (list.area.isEmpty()) {
        return;
    }

    const snapshot = projection.workspaces;
    const active = activeId(projection);
    if (snapshot.count == 0) {
        const fallback = projection.tabs.displayedWorkspaceName();
        try list.context.label(list.area, if (fallback.len != 0) fallback else "workspace");
        return;
    }

    const active_index = if (active) |id| snapshot.indexOf(id) else null;
    const collapsed = projection.workspace_list_collapsed or list.desiredWidth() > list.area.w;
    var strip: Strip = .{ .area = list.area };
    if (collapsed) {
        var counter: [32]u8 = undefined;
        const text = std.fmt.bufPrint(&counter, " +{d} ", .{snapshot.count - 1}) catch unreachable;
        const counter_width = if (snapshot.count > 1) @min(core.measure(text), list.area.w) else 0;
        const current_index = active_index orelse 0;
        const label_width = @min(core.measure(list.name(current_index)) +| 2, strip.remaining() -| counter_width);
        try list.draw(strip.take(label_width), current_index);
        if (counter_width != 0) {
            try list.context.button(.{ .area = strip.take(counter_width), .intent = .toggle_workspace_list, .text = text });
        }

        return;
    }

    for (0..snapshot.count) |index| {
        try list.draw(strip.take(core.measure(list.name(index)) +| 2), index);
        _ = strip.take(1);
    }
}

fn desiredWidth(list: WorkspaceList) u16 {
    var total: u16 = 0;
    for (0..list.context.projection.workspaces.count) |index| {
        total +|= core.measure(list.name(index)) +| 2;
        total +|= @intFromBool(index != 0);
    }

    return total;
}

fn name(list: WorkspaceList, index: usize) []const u8 {
    const projection = list.context.projection;
    if (activeId(projection) == projection.workspaces.workspaceAt(index)) {
        const current = projection.tabs.displayedWorkspaceName();
        if (current.len != 0) {
            return current;
        }
    }

    return projection.workspaces.nameAt(index);
}

fn draw(list: WorkspaceList, area: core.Rect, index: usize) !void {
    var buffer: [core.max_workspace_name_bytes + 8]u8 = undefined;
    const label = std.fmt.bufPrint(&buffer, " {s} ", .{list.name(index)}) catch unreachable;
    const id = list.context.projection.workspaces.workspaceAt(index);
    try list.context.button(.{ .area = area, .intent = .{ .select_workspace = id }, .text = label, .active = activeId(list.context.projection) == id });
}

fn activeId(projection: *const client.Projection) ?core.WorkspaceId {
    const location = projection.tabs.workspace orelse return null;
    return switch (location) {
        .workspace => |id| id,
        .worktree => null,
    };
}

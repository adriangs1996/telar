//! Numbered workspace pills in the top bar. The active one fills with
//! `accent`; a pill whose workspace holds a blocked or failed agent carries
//! an attention dot in that agent's status colour. When the pills do not
//! fit, or the list is collapsed, only the active one and a `+N` counter
//! remain, as the cell list did.
const std = @import("std");
const client = @import("telar-client");
const core = @import("telar-core");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const attention = @import("attention.zig");
const Label = @import("Label.zig");
const WorkspacePills = @This();

context: *Context,
area: Rect,

/// Paints left to right and returns the pixels used.
/// Example: `const used = try pills.paint();`
pub fn paint(pills: WorkspacePills) !f32 {
    const projection = pills.context.projection;
    const canvas = pills.context.canvas;
    if (pills.area.width <= 0) {
        return 0;
    }

    const snapshot = projection.workspaces;
    if (snapshot.count == 0) {
        const fallback = projection.tabs.displayedWorkspaceName();
        const label: Label = .{ .text = if (fallback.len != 0) fallback else "workspace", .color = canvas.theme.palette.subtext0, .face = .sans };
        return try canvas.textAt(pills.area, label);
    }

    const active = activeId(projection);
    const active_index = if (active) |id| snapshot.indexOf(id) else null;
    const gap = canvas.chrome.px(6);
    const collapsed = projection.workspace_list_collapsed or try pills.desiredWidth(gap) > pills.area.width;
    var x = pills.area.x;
    if (collapsed) {
        const current = active_index orelse 0;
        var counter_storage: [32]u8 = undefined;
        const counter = std.fmt.bufPrint(&counter_storage, "+{d}", .{snapshot.count - 1}) catch unreachable;
        const counter_width = if (snapshot.count > 1) try pills.pillWidth(counter, null) else 0;
        const available = @max(0, pills.area.width - counter_width - gap);
        x += try pills.draw(pills.slot(x, available), current);
        if (counter_width != 0) {
            x += gap;
            try pills.context.pill(.{
                .area = pills.slot(x, @min(counter_width, pills.area.x + pills.area.width - x)),
                .intent = .toggle_workspace_list,
                .text = counter,
                .inset = canvas.chrome.px(inset),
            });
            x += counter_width;
        }

        return x - pills.area.x;
    }

    for (0..snapshot.count) |index| {
        if (index != 0) {
            x += gap;
        }

        x += try pills.draw(pills.slot(x, pills.area.x + pills.area.width - x), index);
    }

    return x - pills.area.x;
}

fn desiredWidth(pills: WorkspacePills, gap: f32) !f32 {
    var total: f32 = 0;
    const projection = pills.context.projection;
    for (0..projection.workspaces.count) |index| {
        var storage: [core.max_workspace_name_bytes + 8]u8 = undefined;
        const dot = pills.dotColor(index);
        total += try pills.pillWidth(pills.labelText(&storage, index), dot);
        if (index != 0) {
            total += gap;
        }
    }

    return total;
}

// `room` is the slot the pill may occupy; the pill takes what its label needs.
fn draw(pills: WorkspacePills, room: Rect, index: usize) !f32 {
    var storage: [core.max_workspace_name_bytes + 8]u8 = undefined;
    const text = pills.labelText(&storage, index);
    const dot = pills.dotColor(index);
    const width = @min(try pills.pillWidth(text, dot), room.width);
    if (width <= 0) {
        return 0;
    }

    const id = pills.context.projection.workspaces.workspaceAt(index);
    try pills.context.pill(.{
        .area = .{ .x = room.x, .y = room.y, .width = width, .height = room.height },
        .intent = .{ .select_workspace = id },
        .text = text,
        .active = activeId(pills.context.projection) == id,
        .inset = pills.context.canvas.chrome.px(inset),
        .dot = dot,
    });
    return width;
}

fn slot(pills: WorkspacePills, x: f32, width: f32) Rect {
    return .{ .x = x, .y = pills.area.y, .width = width, .height = pills.area.height };
}

fn pillWidth(pills: WorkspacePills, text: []const u8, dot: ?core.Color) !f32 {
    const chrome = pills.context.canvas.chrome;
    const measured = try pills.context.canvas.measure(.{ .text = text, .face = .sans });
    const dot_space: f32 = if (dot != null) chrome.px(Context.dot_diameter + Context.dot_gap) else 0;
    return @ceil(measured + 2 * chrome.px(inset) + dot_space);
}

fn labelText(pills: WorkspacePills, storage: []u8, index: usize) []const u8 {
    return std.fmt.bufPrint(storage, "{d} {s}", .{ index + 1, pills.name(index) }) catch unreachable;
}

fn dotColor(pills: WorkspacePills, index: usize) ?core.Color {
    const projection = pills.context.projection;
    return attention.workspaceDot(projection, pills.context.canvas.theme.palette, projection.workspaces.workspaceAt(index));
}

fn name(pills: WorkspacePills, index: usize) []const u8 {
    const projection = pills.context.projection;
    if (activeId(projection) == projection.workspaces.workspaceAt(index)) {
        const current = projection.tabs.displayedWorkspaceName();
        if (current.len != 0) {
            return current;
        }
    }

    return projection.workspaces.nameAt(index);
}

/// The workspace the tabs model currently shows, if it is not a worktree.
/// Example: `const active = WorkspacePills.activeId(projection);`
pub fn activeId(projection: *const client.Projection) ?core.WorkspaceId {
    const location = projection.tabs.workspace orelse return null;
    return switch (location) {
        .workspace => |id| id,
        .worktree => null,
    };
}

const inset: f32 = 10;

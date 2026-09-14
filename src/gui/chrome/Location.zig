//! The selected workspace's location on the right of the top bar, in the
//! monospace face: ` ~/sandbox/telar  main`. The branch comes from the
//! workspace list replica when the runtime reported one; a worktree tab has
//! no entry in that list, so only the tabs model's name can be shown.
//! Tokens drop from the right when the space runs out: branch first.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Context = @import("Context.zig");
const Rect = @import("../render/Rect.zig");
const HomePrefix = @import("HomePrefix.zig");
const WorkspacePills = @import("WorkspacePills.zig");
const LocationText = @import("LocationText.zig");
const Location = @This();

context: *Context,
home: []const u8,

pub const path_glyph = "\u{f07b} ";
pub const branch_glyph = " \u{e0a0} ";

/// Paints right-aligned inside `area` and returns the pixels used.
/// Example: `const used = try location.paint(area);`
pub fn paint(location: Location, area: Rect) !f32 {
    var path_storage: [1024]u8 = undefined;
    var storage: [1200]u8 = undefined;
    const parts = location.text(&path_storage, &storage) orelse return 0;
    const canvas = location.context.canvas;
    const palette = canvas.theme.palette;
    var label = parts.path;
    var width = try canvas.measure(.{ .text = label });
    if (parts.branch.len != 0) {
        const with_branch = std.fmt.bufPrint(storage[storage.len / 2 ..], "{s}{s}{s}", .{ parts.path, branch_glyph, parts.branch }) catch parts.path;
        const branch_width = try canvas.measure(.{ .text = with_branch });
        if (branch_width <= area.width) {
            label = with_branch;
            width = branch_width;
        }
    }

    if (width > area.width) {
        return 0;
    }

    const bounds: Rect = .{ .x = area.x + area.width - width, .y = area.y, .width = width, .height = area.height };
    _ = try canvas.textAt(bounds, .{ .text = label, .color = palette.subtext0 });
    return width;
}

fn text(location: Location, path_storage: []u8, storage: []u8) ?LocationText {
    const projection = location.context.projection;
    const workspaces = projection.workspaces;
    const active = WorkspacePills.activeId(projection) orelse return location.fallback(storage);
    const index = workspaces.indexOf(active) orelse return location.fallback(storage);
    const path = workspaces.pathAt(index);
    if (path.len == 0) {
        return location.fallback(storage);
    }

    const shown = HomePrefix.abbreviate(path_storage, path, location.home);
    return .{
        .path = std.fmt.bufPrint(storage[0 .. storage.len / 2], "{s}{s}", .{ path_glyph, shown }) catch return null,
        .branch = workspaces.branchAt(index),
    };
}

fn fallback(location: Location, storage: []u8) ?LocationText {
    const name = location.context.projection.tabs.displayedWorkspaceName();
    if (name.len == 0) {
        return null;
    }

    return .{ .path = std.fmt.bufPrint(storage[0 .. storage.len / 2], "{s}{s}", .{ path_glyph, name }) catch return null, .branch = "" };
}

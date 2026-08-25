//! Workspace and worktree navigation bar.

const std = @import("std");
const core = @import("telar-core");
const widget = @import("context.zig");
const ui = @import("../ui.zig");

const schema = core.schema;

pub const Input = struct {
    area: ui.Rect,
    sidebar_visible: bool,
    location: ?schema.TabLocation,
    workspace_name: []const u8,
};

pub fn render(context: *widget.Context, input: Input) void {
    const area = input.area;
    if (area.isEmpty()) return;
    const bar_style: ui.Style = .{ .fg = context.palette.text, .bg = context.palette.panel_bg };
    context.buffer.fill(area, " ", bar_style);

    const toggle: ui.Rect = .{ .x = area.x, .y = area.y, .w = @min(area.w, 4), .h = 1 };
    context.hits.add(toggle, .toggle_sidebar);
    const toggle_style: ui.Style = if (context.isHovered(.toggle_sidebar))
        .{
            .fg = context.palette.accent,
            .bg = context.palette.surface1,
            .flags = .{ .bold = true, .underline = .single },
        }
    else
        .{ .fg = context.palette.accent, .bg = context.palette.panel_bg, .flags = .{ .bold = true } };
    _ = context.buffer.writeText(
        toggle,
        toggle.x,
        toggle.y,
        if (input.sidebar_visible) "[<]" else "[>]",
        toggle_style,
    );

    var workspace_buffer: [schema.max_workspace_name_bytes + 12]u8 = undefined;
    var worktree_buffer: [48]u8 = undefined;
    const workspace, const worktree = locationLabels(
        input.location,
        input.workspace_name,
        &workspace_buffer,
        &worktree_buffer,
    );
    var x: u16 = toggle.x + toggle.w + 1;
    const workspace_width = @min(ui.measure(workspace) + 2, area.w -| x);
    const workspace_rect: ui.Rect = .{ .x = x, .y = area.y, .w = workspace_width, .h = 1 };
    context.hits.add(workspace_rect, .active_workspace);
    _ = context.buffer.writeTruncated(
        workspace_rect,
        x,
        area.y,
        workspace,
        workspace_width,
        hoveredStyle(context, .active_workspace),
    );
    x += workspace_width + @intFromBool(workspace_width != 0);

    const worktree_width = area.w -| x;
    const worktree_rect: ui.Rect = .{ .x = x, .y = area.y, .w = worktree_width, .h = 1 };
    context.hits.add(worktree_rect, .active_worktree);
    _ = context.buffer.writeTruncated(
        worktree_rect,
        x,
        area.y,
        worktree,
        worktree_width,
        hoveredStyle(context, .active_worktree),
    );
}

fn locationLabels(
    location: ?schema.TabLocation,
    workspace_name: []const u8,
    workspace_buffer: []u8,
    worktree_buffer: []u8,
) struct { []const u8, []const u8 } {
    const value = location orelse return .{ " workspace - ", " worktree - " };
    return switch (value.workspace) {
        .workspace => |workspace| .{
            if (workspace_name.len == 0)
                std.fmt.bufPrint(workspace_buffer, " workspace {d} ", .{schema.id.raw(workspace)}) catch " workspace "
            else
                std.fmt.bufPrint(workspace_buffer, " workspace {s} ", .{workspace_name}) catch " workspace ",
            " worktree - ",
        },
        .worktree => |worktree| .{
            " workspace - ",
            std.fmt.bufPrint(worktree_buffer, " worktree {d} ", .{schema.id.raw(worktree)}) catch " worktree ",
        },
    };
}

fn hoveredStyle(context: *const widget.Context, action: widget.Action) ui.Style {
    return if (context.isHovered(action))
        .{
            .fg = context.palette.text,
            .bg = context.palette.surface0,
            .flags = .{ .bold = true, .underline = .single },
        }
    else
        .{ .fg = context.palette.subtext0, .bg = context.palette.panel_bg };
}

test "workspace label uses the name from the runtime snapshot" {
    var workspace_buffer: [schema.max_workspace_name_bytes + 12]u8 = undefined;
    var worktree_buffer: [48]u8 = undefined;
    const workspace, const worktree = locationLabels(
        .{
            .workspace = .{ .workspace = @enumFromInt(7) },
            .tab_id = @enumFromInt(3),
        },
        "telar",
        &workspace_buffer,
        &worktree_buffer,
    );

    try std.testing.expectEqualStrings(" workspace telar ", workspace);
    try std.testing.expectEqualStrings(" worktree - ", worktree);
}

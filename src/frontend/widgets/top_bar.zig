//! Workspace navigation bar with the proxy interception badge.
//!
//! The bar lists every open workspace from the runtime's workspace-list
//! snapshot, highlights the one this client sits in, and switches on click.
//! The list collapses to `active +N` on user request or when the row cannot
//! fit it; the TLS badge never disappears while interception is on.

const std = @import("std");
const core = @import("telar-core");
const bars = @import("../bars/root.zig");
const bar_content = @import("bar_content.zig");
const status_bar = @import("status_bar.zig");
const widget = @import("context.zig");
const workspace_list = @import("../workspace/root.zig").workspace_list;
const ui = @import("../ui/root.zig");

const schema = core.schema;
const empty_right: bars.Slot = .empty;

pub const Input = struct {
    area: ui.Rect,
    sidebar_visible: bool,
    location: ?schema.TabLocation,
    workspace_name: []const u8,
    workspaces: *const workspace_list.Snapshot,
    collapsed: bool,
    proxy_tls_active: bool,
    right: *const bars.Slot = &empty_right,
    system_metrics: ?status_bar.Metrics = null,
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
    context.buffer.fill(toggle, " ", toggle_style);
    if (toggle.w != 0) _ = context.drawIcon(
        toggle,
        toggle.x + (toggle.w - 1) / 2,
        toggle.y,
        if (input.sidebar_visible) .sidebar_collapse else .sidebar_expand,
        toggle_style,
    );

    // The badge is reserved first so a long workspace list cannot push the
    // interception signal off screen.
    const safe_start = toggle.x + toggle.w + 1;
    const badge_width: u16 = if (input.proxy_tls_active) @min(area.w, 3) else 0;
    const right_capacity = area.x + area.w -| badge_width -| safe_start -| 4;
    const right_width = @min(rightDesiredWidth(input), right_capacity);
    const row_end = area.x + area.w - badge_width - right_width;
    const safe_width = row_end -| safe_start;
    const marker_width = @min(@as(u16, 3), safe_width);
    const active_id = activeWorkspaceId(input.location);
    const group_x = @min(safe_start, row_end);
    const marker_rect: ui.Rect = .{ .x = group_x, .y = area.y, .w = marker_width, .h = 1 };
    context.hits.add(marker_rect, .toggle_workspace_list);
    const marker_style: ui.Style = .{
        .fg = if (context.isHovered(.toggle_workspace_list))
            context.palette.subtext0
        else
            context.palette.overlay0,
        .bg = context.palette.panel_bg,
    };
    context.buffer.fill(marker_rect, " ", marker_style);
    if (marker_width >= 2) _ = context.drawIcon(
        marker_rect,
        group_x + 1,
        area.y,
        .workspace_menu,
        marker_style,
    );
    const list_x = group_x + marker_width;

    if (input.workspaces.count == 0) {
        renderFallback(context, input, list_x, row_end, area.y);
    } else {
        renderList(context, input, active_id, list_x, row_end, area.y);
    }

    renderRight(context, .{
        .x = row_end,
        .y = area.y,
        .w = right_width,
        .h = 1,
    }, input);

    if (input.proxy_tls_active) {
        const badge: ui.Rect = .{
            .x = area.x + area.w - badge_width,
            .y = area.y,
            .w = badge_width,
            .h = 1,
        };
        const badge_style: ui.Style = .{
            .fg = context.palette.peach,
            .bg = context.palette.panel_bg,
            .flags = .{ .bold = true },
        };
        context.buffer.fill(badge, " ", badge_style);
        if (badge_width >= 2) _ = context.drawIcon(
            badge,
            badge.x + 1,
            badge.y,
            .proxy_active,
            badge_style,
        );
    }
}

fn rightDesiredWidth(input: Input) u16 {
    return switch (input.right.*) {
        .content => |*content| content.width(),
        .metrics => status_bar.desiredWidth(input.system_metrics),
        .empty, .tabs => 0,
    };
}

fn renderRight(context: *widget.Context, area: ui.Rect, input: Input) void {
    switch (input.right.*) {
        .content => |*content| bar_content.render(context, area, .{
            .content = content,
            .alignment = .right,
        }),
        .metrics => status_bar.render(context, area, input.system_metrics),
        .empty, .tabs => {},
    }
}

fn renderList(
    context: *widget.Context,
    input: Input,
    active_id: ?schema.WorkspaceId,
    start_x: u16,
    row_end: u16,
    y: u16,
) void {
    const snapshot = input.workspaces;
    const available = row_end -| start_x;
    const active_index = if (active_id) |id| snapshot.indexOf(id) else null;
    const collapsed = input.collapsed or
        !listFits(snapshot, active_index, input.workspace_name, available);
    var x = start_x;

    if (collapsed) {
        const shown = active_index orelse 0;
        x = drawWorkspace(
            context,
            snapshot,
            shown,
            active_index,
            input.workspace_name,
            x,
            row_end,
            y,
        );
        if (snapshot.count > 1) {
            var counter_buffer: [8]u8 = undefined;
            const counter = std.fmt.bufPrint(&counter_buffer, " +{d} ", .{
                snapshot.count - 1,
            }) catch " + ";
            const width = @min(ui.measure(counter), row_end -| x);
            const rect: ui.Rect = .{ .x = x, .y = y, .w = width, .h = 1 };
            context.hits.add(rect, .toggle_workspace_list);
            _ = context.buffer.writeTruncated(rect, x, y, counter, width, .{
                .fg = if (context.isHovered(.toggle_workspace_list))
                    context.palette.text
                else
                    context.palette.subtext0,
                .bg = context.palette.panel_bg,
            });
        }
        return;
    }

    for (0..snapshot.count) |index| {
        if (x >= row_end) break;
        x = drawWorkspace(
            context,
            snapshot,
            index,
            active_index,
            input.workspace_name,
            x,
            row_end,
            y,
        );
    }
}

fn drawWorkspace(
    context: *widget.Context,
    snapshot: *const workspace_list.Snapshot,
    index: usize,
    active_index: ?usize,
    active_name: []const u8,
    x: u16,
    row_end: u16,
    y: u16,
) u16 {
    var label_buffer: [workspace_list.max_name_bytes + core.schema.max_git_branch_bytes + 8]u8 = undefined;
    const branch = snapshot.branchAt(index);
    const dirty_mark: []const u8 = if (snapshot.dirtyAt(index)) "*" else "";
    const label = if (branch.len != 0)
        std.fmt.bufPrint(&label_buffer, " {s} \u{2387}{s}{s} ", .{
            workspaceNameAt(snapshot, index, active_index, active_name),
            branch,
            dirty_mark,
        }) catch " workspace "
    else
        std.fmt.bufPrint(&label_buffer, " {s} ", .{
            workspaceNameAt(snapshot, index, active_index, active_name),
        }) catch " workspace ";
    const width = @min(ui.measure(label), row_end -| x);
    if (width == 0) return x;
    const rect: ui.Rect = .{ .x = x, .y = y, .w = width, .h = 1 };
    const is_active = active_index != null and active_index.? == index;
    const action: widget.Action = if (is_active)
        .active_workspace
    else
        .{ .select_workspace = snapshot.workspaceAt(index) };
    context.hits.add(rect, action);
    const style: ui.Style = if (is_active)
        .{
            .fg = context.palette.text,
            .bg = if (context.isHovered(action))
                context.palette.surface0
            else
                context.palette.panel_bg,
            .underline_color = context.palette.accent,
            .flags = .{ .bold = true, .underline = .single },
        }
    else if (context.isHovered(action))
        .{ .fg = context.palette.text, .bg = context.palette.surface0 }
    else
        .{ .fg = context.palette.overlay0, .bg = context.palette.panel_bg };
    _ = context.buffer.writeTruncated(rect, x, y, label, width, style);
    return x + width;
}

fn renderFallback(
    context: *widget.Context,
    input: Input,
    x: u16,
    row_end: u16,
    y: u16,
) void {
    var workspace_buffer: [schema.max_workspace_name_bytes + 16]u8 = undefined;
    const workspace = workspaceLabel(input.location, input.workspace_name, &workspace_buffer);
    const width = @min(ui.measure(workspace) + 1, row_end -| x);
    if (width == 0) return;
    const rect: ui.Rect = .{ .x = x, .y = y, .w = width, .h = 1 };
    context.hits.add(rect, .active_workspace);
    const style: ui.Style = .{
        .fg = context.palette.text,
        .bg = if (context.isHovered(.active_workspace))
            context.palette.surface0
        else
            context.palette.panel_bg,
        .underline_color = context.palette.accent,
        .flags = .{ .bold = true, .underline = .single },
    };
    _ = context.buffer.writeTruncated(rect, x, y, workspace, width, style);
}

fn listFits(
    snapshot: *const workspace_list.Snapshot,
    active_index: ?usize,
    active_name: []const u8,
    available: u16,
) bool {
    return listWidth(snapshot, active_index, active_name) <= available;
}

fn listWidth(
    snapshot: *const workspace_list.Snapshot,
    active_index: ?usize,
    active_name: []const u8,
) u16 {
    var total: u16 = 0;
    for (0..snapshot.count) |index| {
        total +|= ui.measure(workspaceNameAt(snapshot, index, active_index, active_name)) + 2;
    }
    return total;
}

fn workspaceNameAt(
    snapshot: *const workspace_list.Snapshot,
    index: usize,
    active_index: ?usize,
    active_name: []const u8,
) []const u8 {
    if (active_name.len != 0 and active_index != null and active_index.? == index)
        return workspace_list.truncateName(active_name);
    return snapshot.nameAt(index);
}

fn activeWorkspaceId(location: ?schema.TabLocation) ?schema.WorkspaceId {
    const value = location orelse return null;
    return switch (value.workspace) {
        .workspace => |workspace| workspace,
        .worktree => null,
    };
}

/// Fallback for the moment before the first workspace-list snapshot lands.
/// Worktrees stay out of the chrome until their workflow is settled; a
/// worktree-located client still names its container by id.
fn workspaceLabel(
    location: ?schema.TabLocation,
    workspace_name: []const u8,
    buffer: []u8,
) []const u8 {
    const value = location orelse return "-";
    return switch (value.workspace) {
        .workspace => |workspace| if (workspace_name.len == 0)
            std.fmt.bufPrint(buffer, "workspace {d}", .{schema.id.raw(workspace)}) catch "workspace"
        else
            workspace_name,
        .worktree => |worktree| std.fmt.bufPrint(
            buffer,
            "worktree {d}",
            .{schema.id.raw(worktree)},
        ) catch "worktree",
    };
}

test "workspace label uses the name from the runtime snapshot" {
    var buffer: [schema.max_workspace_name_bytes + 16]u8 = undefined;
    const label = workspaceLabel(
        .{
            .workspace = .{ .workspace = @enumFromInt(7) },
            .tab_id = @enumFromInt(3),
        },
        "telar",
        &buffer,
    );
    try std.testing.expectEqualStrings("telar", label);
}

test "worktree locations fall back to their id and missing locations to a dash" {
    var buffer: [schema.max_workspace_name_bytes + 16]u8 = undefined;
    try std.testing.expectEqualStrings("worktree 9", workspaceLabel(
        .{
            .workspace = .{ .worktree = @enumFromInt(9) },
            .tab_id = @enumFromInt(3),
        },
        "",
        &buffer,
    ));
    try std.testing.expectEqualStrings("-", workspaceLabel(null, "telar", &buffer));
}

test "the list collapses when the row cannot fit every workspace" {
    var snapshot: workspace_list.Snapshot = .{};
    const entries = [_]workspace_list.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/w/api", .tab_count = 1 },
    };
    _ = try snapshot.replace(.{ .revision = 1, .entries = &entries });
    // " telar " + " api " = 12 columns.
    try std.testing.expect(listFits(&snapshot, null, "", 12));
    try std.testing.expect(!listFits(&snapshot, null, "", 11));
}

test "the active name replaces only the active workspace snapshot name" {
    var snapshot: workspace_list.Snapshot = .{};
    const entries = [_]workspace_list.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/w/api", .tab_count = 1 },
    };
    _ = try snapshot.replace(.{ .revision = 1, .entries = &entries });

    try std.testing.expectEqualStrings("agents", workspaceNameAt(&snapshot, 0, 0, "agents"));
    try std.testing.expectEqualStrings("api", workspaceNameAt(&snapshot, 1, 0, "agents"));
    // " agents " + " api " = 13 columns.
    try std.testing.expect(listFits(&snapshot, 0, "agents", 13));
    try std.testing.expect(!listFits(&snapshot, 0, "agents", 12));
}

test "sidebar toggle publishes the matching Nerd Font action icon" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var plan: ui.icons.Plan = .{};
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &ui.theme.default_theme.palette,
        .hovered = null,
        .icon_theme = .nerd_font,
        .icon_plan = &plan,
    };
    const workspaces: workspace_list.Snapshot = .{};
    const input: Input = .{
        .area = buffer.area(),
        .sidebar_visible = true,
        .location = null,
        .workspace_name = "telar",
        .workspaces = &workspaces,
        .collapsed = false,
        .proxy_tls_active = false,
    };

    render(&context, input);
    try std.testing.expect(plan.len >= 1);
    try std.testing.expectEqual(ui.icons.Icon.sidebar_collapse, plan.slice()[0].icon);

    plan.reset();
    var hidden = input;
    hidden.sidebar_visible = false;
    render(&context, hidden);
    try std.testing.expect(plan.len >= 1);
    try std.testing.expectEqual(ui.icons.Icon.sidebar_expand, plan.slice()[0].icon);
}

test "proxy badge reserves the right edge before workspace navigation" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &ui.theme.default_theme.palette,
        .hovered = null,
    };
    const workspaces: workspace_list.Snapshot = .{};

    render(&context, .{
        .area = buffer.area(),
        .sidebar_visible = true,
        .location = null,
        .workspace_name = "telar",
        .workspaces = &workspaces,
        .collapsed = false,
        .proxy_tls_active = true,
    });

    const badge_x = @as(usize, buffer.w) - 2;
    try std.testing.expectEqualStrings(
        ui.icons.Icon.proxy_active.unicodeGlyph(),
        buffer.cells[badge_x].text(),
    );
    try std.testing.expect(hits.at(@intCast(badge_x), 0) == null);
}

test "configured right content stops before the permanent proxy badge" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &ui.theme.default_theme.palette,
        .hovered = null,
    };
    const workspaces: workspace_list.Snapshot = .{};
    var content: bars.Content = .{};
    try content.append("quota", null, .{ .foreground = .{ .palette = .accent } });
    const right: bars.Slot = .{ .content = content };

    render(&context, .{
        .area = buffer.area(),
        .sidebar_visible = true,
        .location = null,
        .workspace_name = "telar",
        .workspaces = &workspaces,
        .collapsed = false,
        .proxy_tls_active = true,
        .right = &right,
    });

    try std.testing.expectEqualStrings("q", buffer.at(32, 0).?.text());
    try std.testing.expectEqualStrings("a", buffer.at(36, 0).?.text());
    try std.testing.expectEqualStrings(
        ui.icons.Icon.proxy_active.unicodeGlyph(),
        buffer.at(38, 0).?.text(),
    );
    try std.testing.expectEqualDeep(
        ui.theme.default_theme.palette.accent,
        buffer.at(32, 0).?.style.fg,
    );
}

test "workspace navigation starts after the sidebar toggle" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &ui.theme.default_theme.palette,
        .hovered = null,
    };
    var workspaces: workspace_list.Snapshot = .{};
    const entries = [_]workspace_list.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1 },
    };
    _ = try workspaces.replace(.{ .revision = 1, .entries = &entries });

    render(&context, .{
        .area = buffer.area(),
        .sidebar_visible = true,
        .location = .{
            .workspace = .{ .workspace = @enumFromInt(1) },
            .tab_id = @enumFromInt(1),
        },
        .workspace_name = "telar",
        .workspaces = &workspaces,
        .collapsed = false,
        .proxy_tls_active = false,
    });

    // The marker starts after the four-column toggle and its one-column gap.
    try std.testing.expectEqual(widget.Action.toggle_workspace_list, hits.at(6, 0).?);
    try std.testing.expectEqual(widget.Action.active_workspace, hits.at(8, 0).?);
    try std.testing.expect(hits.at(15, 0) == null);
}

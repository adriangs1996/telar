//! Workspace navigation bar with the proxy interception badge.
//!
//! The bar lists every open workspace from the runtime's workspace-list
//! snapshot, highlights the one this client sits in, and switches on click.
//! The list collapses to `active +N` on user request or when the row cannot
//! fit it; the TLS badge never disappears while interception is on.

const std = @import("std");
const core = @import("telar-core");
const widget = @import("context.zig");
const workspace_model = @import("workspace_model.zig");
const ui = @import("../ui.zig");

const schema = core.schema;

pub const Input = struct {
    area: ui.Rect,
    sidebar_visible: bool,
    location: ?schema.TabLocation,
    workspace_name: []const u8,
    workspaces: *const workspace_model.Snapshot,
    collapsed: bool,
    proxy_tls_active: bool,
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

    // The badge is reserved first so a long workspace list cannot push the
    // interception signal off screen.
    const badge_width: u16 = if (input.proxy_tls_active) ui.measure(" \u{26e8} ") else 0;
    const row_end = area.x + area.w - badge_width;

    var x: u16 = toggle.x + toggle.w + 1;
    const marker = " \u{2756} ";
    const marker_width = @min(ui.measure(marker), row_end -| x);
    const marker_rect: ui.Rect = .{ .x = x, .y = area.y, .w = marker_width, .h = 1 };
    context.hits.add(marker_rect, .toggle_workspace_list);
    _ = context.buffer.writeTruncated(marker_rect, x, area.y, marker, marker_width, .{
        .fg = if (context.isHovered(.toggle_workspace_list))
            context.palette.subtext0
        else
            context.palette.overlay0,
        .bg = context.palette.panel_bg,
    });
    x += marker_width;

    const active_id = activeWorkspaceId(input.location);
    if (input.workspaces.count == 0) {
        renderFallback(context, input, x, row_end, area.y);
    } else {
        renderList(context, input, active_id, x, row_end, area.y);
    }

    if (input.proxy_tls_active) {
        _ = context.buffer.writeRight(area, area.y, " \u{26e8} ", .{
            .fg = context.palette.peach,
            .bg = context.palette.panel_bg,
            .flags = .{ .bold = true },
        });
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
    snapshot: *const workspace_model.Snapshot,
    index: usize,
    active_index: ?usize,
    active_name: []const u8,
    x: u16,
    row_end: u16,
    y: u16,
) u16 {
    var label_buffer: [workspace_model.max_name_bytes + 2]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, " {s} ", .{
        workspaceNameAt(snapshot, index, active_index, active_name),
    }) catch
        " workspace ";
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
    snapshot: *const workspace_model.Snapshot,
    active_index: ?usize,
    active_name: []const u8,
    available: u16,
) bool {
    var total: u16 = 0;
    for (0..snapshot.count) |index| {
        total +|= ui.measure(workspaceNameAt(snapshot, index, active_index, active_name)) + 2;
        if (total > available) return false;
    }
    return true;
}

fn workspaceNameAt(
    snapshot: *const workspace_model.Snapshot,
    index: usize,
    active_index: ?usize,
    active_name: []const u8,
) []const u8 {
    if (active_name.len != 0 and active_index != null and active_index.? == index)
        return workspace_model.truncateName(active_name);
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
    var snapshot: workspace_model.Snapshot = .{};
    const entries = [_]workspace_model.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/w/api", .tab_count = 1 },
    };
    _ = try snapshot.replace(.{ .revision = 1, .entries = &entries });
    // " telar " + " api " = 12 columns.
    try std.testing.expect(listFits(&snapshot, null, "", 12));
    try std.testing.expect(!listFits(&snapshot, null, "", 11));
}

test "the active name replaces only the active workspace snapshot name" {
    var snapshot: workspace_model.Snapshot = .{};
    const entries = [_]workspace_model.EntryInput{
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

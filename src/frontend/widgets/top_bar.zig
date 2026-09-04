//! Workspace navigation bar with the proxy interception badge.
//!
//! The bar lists every open workspace from the runtime's workspace-list
//! snapshot, highlights the one this client sits in, and switches on click.
//! The list collapses to `active +N` on user request or when the row cannot
//! fit it; the TLS badge remains while interception or system trust is on.

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
    proxy_tls_scope: schema.ProxyScope = .exact,
    proxy_system_trusted: bool = false,
    right: *const bars.Slot = &empty_right,
    system_metrics: ?status_bar.Metrics = null,
};

const ListInput = struct {
    area: ui.Rect,
    active_id: ?schema.WorkspaceId,
};

const WorkspaceDraw = struct {
    snapshot: *const workspace_list.Snapshot,
    index: usize,
    active_index: ?usize,
    active_name: []const u8,
    area: ui.Rect,
};

pub fn render(context: *widget.Context, input: Input) void {
    const area = input.area;

    if (area.isEmpty()) {
        return;
    }

    const bar_style: ui.Style = .{
        .fg = context.palette.text,
        .bg = context.palette.panel_bg,
    };
    context.buffer.fill(area, .{ .glyph = " ", .style = bar_style });

    const toggle: ui.Rect = .{
        .x = area.x,
        .y = area.y,
        .w = @min(area.w, 4),
        .h = 1,
    };

    context.hits.add(toggle, .toggle_sidebar);

    const toggle_style: ui.Style =
        if (context.isHovered(.toggle_sidebar))
            .{
                .fg = context.palette.accent,
                .bg = context.palette.surface1,
                .flags = .{ .bold = true, .underline = .single },
            }
        else
            .{
                .fg = context.palette.accent,
                .bg = context.palette.panel_bg,
                .flags = .{
                    .bold = true,
                },
            };

    context.buffer.fill(toggle, .{ .glyph = " ", .style = toggle_style });

    if (toggle.w != 0) {
        _ = context.drawIcon(.{
            .area = toggle,
            .point = .{ .x = toggle.x + (toggle.w - 1) / 2, .y = toggle.y },
            .icon = if (input.sidebar_visible) .sidebar_collapse else .sidebar_expand,
            .style = toggle_style,
        });
    }

    // The badge is reserved first so a long workspace list cannot push the
    // interception or installed-trust signal off screen.
    const safe_start = toggle.x + toggle.w + 1;
    const badge_visible = input.proxy_tls_active or input.proxy_system_trusted;
    const badge_width: u16 = if (badge_visible) @min(area.w, 3) else 0;
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
    context.buffer.fill(marker_rect, .{ .glyph = " ", .style = marker_style });
    if (marker_width >= 2) {
        _ = context.drawIcon(.{
            .area = marker_rect,
            .point = .{ .x = group_x + 1, .y = area.y },
            .icon = .workspace_menu,
            .style = marker_style,
        });
    }
    const list_x = group_x + marker_width;

    if (input.workspaces.count == 0) {
        renderFallback(context, input, .{ .x = list_x, .y = area.y, .w = row_end -| list_x, .h = 1 });
    } else {
        renderList(context, input, .{
            .area = .{ .x = list_x, .y = area.y, .w = row_end -| list_x, .h = 1 },
            .active_id = active_id,
        });
    }

    renderRight(context, .{
        .x = row_end,
        .y = area.y,
        .w = right_width,
        .h = 1,
    }, input);

    if (badge_visible) {
        const badge: ui.Rect = .{
            .x = area.x + area.w - badge_width,
            .y = area.y,
            .w = badge_width,
            .h = 1,
        };
        const badge_style: ui.Style = .{
            .fg = if (!input.proxy_tls_active)
                context.palette.yellow
            else if (input.proxy_tls_scope == .wildcard)
                context.palette.red
            else
                context.palette.peach,
            .bg = context.palette.panel_bg,
            .flags = .{ .bold = true },
        };
        context.buffer.fill(badge, .{ .glyph = " ", .style = badge_style });
        if (badge_width >= 2) {
            _ = context.drawIcon(.{
                .area = badge,
                .point = .{ .x = badge.x + 1, .y = badge.y },
                .icon = .proxy_active,
                .style = badge_style,
            });
        }
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

fn renderList(context: *widget.Context, input: Input, list: ListInput) void {
    const snapshot = input.workspaces;
    const row_end = list.area.x + list.area.w;
    const active_index = if (list.active_id) |id| snapshot.indexOf(id) else null;
    const collapsed = input.collapsed or
        !listFits(snapshot, active_index, input.workspace_name, list.area.w);
    var x = list.area.x;

    if (collapsed) {
        const shown = active_index orelse 0;
        x = drawWorkspace(context, .{
            .snapshot = snapshot,
            .index = shown,
            .active_index = active_index,
            .active_name = input.workspace_name,
            .area = .{ .x = x, .y = list.area.y, .w = row_end -| x, .h = 1 },
        });
        if (snapshot.count > 1) {
            var counter_buffer: [8]u8 = undefined;
            const counter = std.fmt.bufPrint(&counter_buffer, " +{d} ", .{
                snapshot.count - 1,
            }) catch " + ";
            const width = @min(ui.measure(counter), row_end -| x);
            const rect: ui.Rect = .{ .x = x, .y = list.area.y, .w = width, .h = 1 };
            context.hits.add(rect, .toggle_workspace_list);
            _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = x, .y = list.area.y }, .text = counter, .max_width = width, .style = .{
                .fg = if (context.isHovered(.toggle_workspace_list))
                    context.palette.text
                else
                    context.palette.subtext0,
                .bg = context.palette.panel_bg,
            } });
        }
        return;
    }

    for (0..snapshot.count) |index| {
        if (x >= row_end) {
            break;
        }
        x = drawWorkspace(context, .{
            .snapshot = snapshot,
            .index = index,
            .active_index = active_index,
            .active_name = input.workspace_name,
            .area = .{ .x = x, .y = list.area.y, .w = row_end -| x, .h = 1 },
        });
    }
}

fn drawWorkspace(context: *widget.Context, draw: WorkspaceDraw) u16 {
    var label_buffer: [workspace_list.max_name_bytes + 4]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, " {s} ", .{
        workspaceNameAt(draw.snapshot, draw.index, draw.active_index, draw.active_name),
    }) catch " workspace ";
    const width = @min(ui.measure(label), draw.area.w);
    if (width == 0) {
        return draw.area.x;
    }

    const rect: ui.Rect = .{ .x = draw.area.x, .y = draw.area.y, .w = width, .h = 1 };
    const is_active = draw.active_index != null and draw.active_index.? == draw.index;
    const action: widget.Action = if (is_active)
        .active_workspace
    else
        .{ .select_workspace = draw.snapshot.workspaceAt(draw.index) };
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

    _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = draw.area.x, .y = draw.area.y }, .text = label, .max_width = width, .style = style });

    return draw.area.x + width;
}

fn renderFallback(context: *widget.Context, input: Input, area: ui.Rect) void {
    var workspace_buffer: [schema.max_workspace_name_bytes + 16]u8 = undefined;
    const workspace = workspaceLabel(input.location, input.workspace_name, &workspace_buffer);
    const width = @min(ui.measure(workspace) + 1, area.w);
    if (width == 0) {
        return;
    }

    const rect: ui.Rect = .{ .x = area.x, .y = area.y, .w = width, .h = 1 };
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

    _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = area.x, .y = area.y }, .text = workspace, .max_width = width, .style = style });
}

fn listFits(snapshot: *const workspace_list.Snapshot, active_index: ?usize, active_name: []const u8, available: u16) bool {
    return listWidth(snapshot, active_index, active_name) <= available;
}

fn listWidth(snapshot: *const workspace_list.Snapshot, active_index: ?usize, active_name: []const u8) u16 {
    var total: u16 = 0;
    for (0..snapshot.count) |index| {
        total +|= ui.measure(workspaceNameAt(snapshot, index, active_index, active_name)) + 2;
    }
    return total;
}

fn workspaceNameAt(snapshot: *const workspace_list.Snapshot, index: usize, active_index: ?usize, active_name: []const u8) []const u8 {
    if (active_name.len != 0 and active_index != null and active_index.? == index) {
        return workspace_list.truncateName(active_name);
    }
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
fn workspaceLabel(location: ?schema.TabLocation, workspace_name: []const u8, buffer: []u8) []const u8 {
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

test "the workspace label ignores git branch and dirty state" {
    var snapshot: workspace_list.Snapshot = .{};
    const entries = [_]workspace_list.EntryInput{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1, .branch = "main", .dirty = true },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/w/api", .tab_count = 1, .branch = "main" },
    };
    _ = try snapshot.replace(.{ .revision = 1, .entries = &entries });
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: widget.Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &ui.theme.default_theme.palette,
        .hovered = null,
    };

    const end = drawWorkspace(&context, .{
        .snapshot = &snapshot,
        .index = 0,
        .active_index = null,
        .active_name = "",
        .area = .{ .x = 0, .y = 0, .w = 40, .h = 1 },
    });
    var text: [16]u8 = undefined;
    var len: usize = 0;
    for (0..end) |x| {
        const cell_text = buffer.at(@intCast(x), 0).?.text();
        @memcpy(text[len .. len + cell_text.len], cell_text);
        len += cell_text.len;
    }
    try std.testing.expectEqualStrings(" telar ", text[0..len]);
    // " telar " + " api " = 12 columns regardless of git state.
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

test "wildcard proxy scope renders a distinct warning badge" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 20, 1);
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
        .proxy_tls_scope = .wildcard,
    });

    const badge = buffer.at(18, 0).?;
    try std.testing.expectEqualStrings(ui.icons.Icon.proxy_active.unicodeGlyph(), badge.text());
    try std.testing.expectEqualDeep(ui.theme.default_theme.palette.red, badge.style.fg);
}

test "installed system trust keeps a yellow badge while the proxy is off" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 20, 1);
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
        .proxy_tls_active = false,
        .proxy_system_trusted = true,
    });

    const badge = buffer.at(18, 0).?;
    try std.testing.expectEqualStrings(ui.icons.Icon.proxy_active.unicodeGlyph(), badge.text());
    try std.testing.expectEqualDeep(ui.theme.default_theme.palette.yellow, badge.style.fg);
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
    try content.append(.{ .text = "quota", .style = .{ .foreground = .{ .palette = .accent } } });
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

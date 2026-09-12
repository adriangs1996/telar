//! Workspace navigation bar with the proxy interception badge.
//!
//! The bar lists every open workspace from the runtime's workspace-list
//! snapshot, highlights the one this client sits in, and switches on click.
//! The list collapses to `active +N` on user request or when the row cannot
//! fit it; the TLS badge remains while interception or system trust is on.

const SlotType = @import("telar-client").Slot;
const ContextType = @import("Context.zig");
const TopBarInput = @import("TopBarInput.zig");
const StyleType = @import("telar-core").Style;
const RectType = @import("telar-core").Rect;
const status_bar = @import("status_bar.zig");
const bar_content = @import("bar_content.zig");
const ListInput = @import("ListInput.zig");
const std = @import("std");
const measure_module = @import("telar-core").measure;
const WorkspaceDraw = @import("WorkspaceDraw.zig");
const max_name_bytes_module = @import("telar-client").max_name_bytes;
const widget = @import("context_support.zig");
const max_workspace_name_bytes_module = @import("telar-core").max_workspace_name_bytes;
const WorkspaceNames = @import("WorkspaceNames.zig");
const WorkspaceListSnapshot = @import("telar-client").WorkspaceListSnapshot;
const truncateName_module = @import("telar-client").truncateName;
const TabLocationType = @import("telar-core").TabLocation;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const raw_module = @import("telar-core").raw;
const EntryInputType = @import("telar-client").EntryInput;
const BufferType = @import("telar-core").Buffer;
const theme_support = @import("telar-client").theme_support;
const PlanType = @import("../ui/Plan.zig");
const IconType = @import("telar-client").Icon;
const ContentType = @import("telar-client").Content;

pub const empty_right: SlotType = .empty;

pub fn render(context: *ContextType, input: TopBarInput) void {
    const area = input.area;

    if (area.isEmpty()) {
        return;
    }

    const bar_style: StyleType = .{
        .fg = context.palette.text,
        .bg = context.palette.panel_bg,
    };
    context.buffer.fill(area, .{ .glyph = " ", .style = bar_style });

    // The telar mark is the only control before the workspace list: it opens
    // and closes the sidebar, and dims while the sidebar is hidden. Collapsing
    // the list is a keyboard action, or the counter shown while collapsed.
    // The mark spans two cells so its square can grow to the row's height.
    const logo: RectType = .{
        .x = area.x,
        .y = area.y,
        .w = @min(area.w, 4),
        .h = 1,
    };

    context.hits.add(logo, .toggle_sidebar);

    const logo_style: StyleType =
        if (context.isHovered(.toggle_sidebar))
            .{
                .fg = context.palette.accent,
                .bg = context.palette.surface1,
                .flags = .{ .bold = true },
            }
        else
            .{
                .fg = if (input.sidebar_visible) context.palette.accent else context.palette.subtext0,
                .bg = context.palette.panel_bg,
                .flags = .{ .bold = true },
            };

    context.buffer.fill(logo, .{ .glyph = " ", .style = logo_style });

    if (logo.w >= 2) {
        _ = context.drawIcon(.{
            .area = logo,
            .point = .{ .x = logo.x + 1, .y = logo.y },
            .icon = .telar_mark,
            .style = logo_style,
            .columns = if (logo.w >= 3) 2 else 1,
        });
    }

    // The badge is reserved first so a long workspace list cannot push the
    // interception or installed-trust signal off screen.
    const safe_start = logo.x + logo.w;
    const badge_visible = input.proxy_tls_active or input.proxy_system_trusted;
    const badge_width: u16 = if (badge_visible) @min(area.w, 3) else 0;
    const right_capacity = area.x + area.w -| badge_width -| safe_start -| 4;
    const right_width = @min(rightDesiredWidth(input), right_capacity);
    const row_end = area.x + area.w - badge_width - right_width;
    const active_id = activeWorkspaceId(input.location);
    const list_x = @min(safe_start, row_end);

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
        const badge: RectType = .{
            .x = area.x + area.w - badge_width,
            .y = area.y,
            .w = badge_width,
            .h = 1,
        };
        const badge_style: StyleType = .{
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

fn rightDesiredWidth(input: TopBarInput) u16 {
    return switch (input.right.*) {
        .content => |*content| content.width(),
        .metrics => status_bar.desiredWidth(input.system_metrics),
        .empty, .tabs => 0,
    };
}

fn renderRight(context: *ContextType, area: RectType, input: TopBarInput) void {
    switch (input.right.*) {
        .content => |*content| bar_content.render(context, area, .{
            .content = content,
            .alignment = .right,
        }),
        .metrics => status_bar.render(context, area, input.system_metrics),
        .empty, .tabs => {},
    }
}

fn renderList(context: *ContextType, input: TopBarInput, list: ListInput) void {
    const snapshot = input.workspaces;
    const row_end = list.area.x + list.area.w;
    const active_index = if (list.active_id) |id| snapshot.indexOf(id) else null;
    const collapsed = input.collapsed or
        !listFits(.{
            .snapshot = snapshot,
            .active_index = active_index,
            .active_name = input.workspace_name,
        }, list.area.w);
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
            const width = @min(measure_module(counter), row_end -| x);
            const rect: RectType = .{ .x = x, .y = list.area.y, .w = width, .h = 1 };
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

fn drawWorkspace(context: *ContextType, draw: WorkspaceDraw) u16 {
    var label_buffer: [max_name_bytes_module + 4]u8 = undefined;
    const label = std.fmt.bufPrint(&label_buffer, " {s} ", .{
        workspaceNameAt(.{
            .snapshot = draw.snapshot,
            .active_index = draw.active_index,
            .active_name = draw.active_name,
        }, draw.index),
    }) catch " workspace ";
    const width = @min(measure_module(label), draw.area.w);
    if (width == 0) {
        return draw.area.x;
    }

    const rect: RectType = .{ .x = draw.area.x, .y = draw.area.y, .w = width, .h = 1 };
    const is_active = draw.active_index != null and draw.active_index.? == draw.index;
    const action: widget.Action = if (is_active)
        .active_workspace
    else
        .{ .select_workspace = draw.snapshot.workspaceAt(draw.index) };
    context.hits.add(rect, action);

    const style: StyleType = if (is_active)
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

fn renderFallback(context: *ContextType, input: TopBarInput, area: RectType) void {
    var workspace_buffer: [max_workspace_name_bytes_module + 16]u8 = undefined;
    const workspace = workspaceLabel(input.location, input.workspace_name, &workspace_buffer);
    const width = @min(measure_module(workspace) + 1, area.w);
    if (width == 0) {
        return;
    }

    const rect: RectType = .{ .x = area.x, .y = area.y, .w = width, .h = 1 };
    context.hits.add(rect, .active_workspace);

    const style: StyleType = .{
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

fn listFits(names: WorkspaceNames, available: u16) bool {
    return listWidth(names.snapshot, names.active_index, names.active_name) <= available;
}

fn listWidth(snapshot: *const WorkspaceListSnapshot, active_index: ?usize, active_name: []const u8) u16 {
    var total: u16 = 0;
    for (0..snapshot.count) |index| {
        total +|= measure_module(workspaceNameAt(.{
            .snapshot = snapshot,
            .active_index = active_index,
            .active_name = active_name,
        }, index)) + 2;
    }
    return total;
}

fn workspaceNameAt(names: WorkspaceNames, index: usize) []const u8 {
    if (names.active_name.len != 0 and names.active_index != null and names.active_index.? == index) {
        return truncateName_module(names.active_name);
    }

    return names.snapshot.nameAt(index);
}

fn activeWorkspaceId(location: ?TabLocationType) ?WorkspaceIdType {
    const value = location orelse return null;
    return switch (value.workspace) {
        .workspace => |workspace| workspace,
        .worktree => null,
    };
}

/// Fallback for the moment before the first workspace-list snapshot lands.
/// Worktrees stay out of the chrome until their workflow is settled; a
/// worktree-located client still names its container by id.
fn workspaceLabel(location: ?TabLocationType, workspace_name: []const u8, buffer: []u8) []const u8 {
    const value = location orelse return "-";
    return switch (value.workspace) {
        .workspace => |workspace| if (workspace_name.len == 0)
            std.fmt.bufPrint(buffer, "workspace {d}", .{raw_module(workspace)}) catch "workspace"
        else
            workspace_name,
        .worktree => |worktree| std.fmt.bufPrint(
            buffer,
            "worktree {d}",
            .{raw_module(worktree)},
        ) catch "worktree",
    };
}

test "workspace label uses the name from the runtime snapshot" {
    var buffer: [max_workspace_name_bytes_module + 16]u8 = undefined;
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
    var buffer: [max_workspace_name_bytes_module + 16]u8 = undefined;
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
    var snapshot: WorkspaceListSnapshot = .{};
    const entries = [_]EntryInputType{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/w/api", .tab_count = 1 },
    };
    _ = try snapshot.replace(.{ .revision = 1, .entries = &entries });
    // " telar " + " api " = 12 columns.
    const names: WorkspaceNames = .{ .snapshot = &snapshot, .active_index = null, .active_name = "" };
    try std.testing.expect(listFits(names, 12));
    try std.testing.expect(!listFits(names, 11));
}

test "the workspace label ignores git branch and dirty state" {
    var snapshot: WorkspaceListSnapshot = .{};
    const entries = [_]EntryInputType{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1, .branch = "main", .dirty = true },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/w/api", .tab_count = 1, .branch = "main" },
    };
    _ = try snapshot.replace(.{ .revision = 1, .entries = &entries });
    var buffer = try BufferType.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: ContextType = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme_support.default_theme.palette,
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
    const names: WorkspaceNames = .{ .snapshot = &snapshot, .active_index = null, .active_name = "" };
    try std.testing.expect(listFits(names, 12));
    try std.testing.expect(!listFits(names, 11));
}

test "the active name replaces only the active workspace snapshot name" {
    var snapshot: WorkspaceListSnapshot = .{};
    const entries = [_]EntryInputType{
        .{ .workspace = @enumFromInt(1), .name = "telar", .path = "/w/telar", .tab_count = 1 },
        .{ .workspace = @enumFromInt(2), .name = "api", .path = "/w/api", .tab_count = 1 },
    };
    _ = try snapshot.replace(.{ .revision = 1, .entries = &entries });

    const names: WorkspaceNames = .{
        .snapshot = &snapshot,
        .active_index = 0,
        .active_name = "agents",
    };
    try std.testing.expectEqualStrings("agents", workspaceNameAt(names, 0));
    try std.testing.expectEqualStrings("api", workspaceNameAt(names, 1));
    // " agents " + " api " = 13 columns.
    try std.testing.expect(listFits(names, 13));
    try std.testing.expect(!listFits(names, 12));
}

test "the telar mark toggles the sidebar and dims while it is hidden" {
    var buffer = try BufferType.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var plan: PlanType = .{};
    var context: ContextType = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme_support.default_theme.palette,
        .hovered = null,
        .icon_theme = .nerd_font,
        .icon_plan = &plan,
    };
    const workspaces: WorkspaceListSnapshot = .{};
    const input: TopBarInput = .{
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
    try std.testing.expectEqual(IconType.telar_mark, plan.slice()[0].icon);
    try std.testing.expectEqual(@as(u16, 2), plan.slice()[0].area.w);
    try std.testing.expectEqual(widget.Action.toggle_sidebar, hits.at(1, 0).?);
    try std.testing.expectEqualDeep(theme_support.default_theme.palette.accent, buffer.at(1, 0).?.style.fg);

    plan.reset();
    hits = .{};
    var hidden = input;
    hidden.sidebar_visible = false;
    render(&context, hidden);
    try std.testing.expect(plan.len >= 1);
    try std.testing.expectEqual(IconType.telar_mark, plan.slice()[0].icon);
    try std.testing.expectEqual(widget.Action.toggle_sidebar, hits.at(1, 0).?);
    try std.testing.expectEqualDeep(theme_support.default_theme.palette.subtext0, buffer.at(1, 0).?.style.fg);
}

test "proxy badge reserves the right edge before workspace navigation" {
    var buffer = try BufferType.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: ContextType = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme_support.default_theme.palette,
        .hovered = null,
    };
    const workspaces: WorkspaceListSnapshot = .{};

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
        IconType.proxy_active.unicodeGlyph(),
        buffer.cells[badge_x].text(),
    );
    try std.testing.expect(hits.at(@intCast(badge_x), 0) == null);
}

test "wildcard proxy scope renders a distinct warning badge" {
    var buffer = try BufferType.init(std.testing.allocator, 20, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: ContextType = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme_support.default_theme.palette,
        .hovered = null,
    };
    const workspaces: WorkspaceListSnapshot = .{};

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
    try std.testing.expectEqualStrings(IconType.proxy_active.unicodeGlyph(), badge.text());
    try std.testing.expectEqualDeep(theme_support.default_theme.palette.red, badge.style.fg);
}

test "installed system trust keeps a yellow badge while the proxy is off" {
    var buffer = try BufferType.init(std.testing.allocator, 20, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: ContextType = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme_support.default_theme.palette,
        .hovered = null,
    };
    const workspaces: WorkspaceListSnapshot = .{};

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
    try std.testing.expectEqualStrings(IconType.proxy_active.unicodeGlyph(), badge.text());
    try std.testing.expectEqualDeep(theme_support.default_theme.palette.yellow, badge.style.fg);
}

test "configured right content stops before the permanent proxy badge" {
    var buffer = try BufferType.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: ContextType = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme_support.default_theme.palette,
        .hovered = null,
    };
    const workspaces: WorkspaceListSnapshot = .{};
    var content: ContentType = .{};
    try content.append(.{ .text = "quota", .style = .{ .foreground = .{ .palette = .accent } } });
    const right: SlotType = .{ .content = content };

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
        IconType.proxy_active.unicodeGlyph(),
        buffer.at(38, 0).?.text(),
    );
    try std.testing.expectEqualDeep(
        theme_support.default_theme.palette.accent,
        buffer.at(32, 0).?.style.fg,
    );
}

test "workspace navigation starts right after the telar mark" {
    var buffer = try BufferType.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: ContextType = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme_support.default_theme.palette,
        .hovered = null,
    };
    var workspaces: WorkspaceListSnapshot = .{};
    const entries = [_]EntryInputType{
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

    // The mark takes four columns and the list follows with nothing between.
    try std.testing.expectEqual(widget.Action.toggle_sidebar, hits.at(0, 0).?);
    try std.testing.expectEqual(widget.Action.toggle_sidebar, hits.at(3, 0).?);
    try std.testing.expectEqual(widget.Action.active_workspace, hits.at(4, 0).?);
    try std.testing.expectEqual(widget.Action.active_workspace, hits.at(10, 0).?);
    try std.testing.expect(hits.at(11, 0) == null);
    for (hits.registered()) |entry| {
        try std.testing.expect(std.meta.activeTag(entry.action) != .toggle_workspace_list);
    }
}

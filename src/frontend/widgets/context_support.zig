//! Frame-scoped widget dependencies and semantic UI actions.

const std = @import("std");
const core = @import("telar-core");
const ui = @import("../ui/root.zig");
pub const theme = ui.theme;
pub const icons = ui.icons;
const notifications = @import("telar-client").notifications;
const agents = @import("telar-client").agents;
const attachments = @import("../attachments/root.zig");

const schema = core.schema;

pub const Action = union(enum) {
    toggle_sidebar,
    resize_sidebar,
    focus_pane: schema.PaneId,
    select_tab: schema.TabId,
    active_workspace,
    select_workspace: schema.WorkspaceId,
    toggle_workspace_list,
    sidebar_focus_agent: agents.AgentKey,
    sidebar_scroll_to: u16,
    notification_activate: notifications.Id,
    notification_dismiss: notifications.Id,
    attachment_open: attachments.Id,
    attachment_dismiss: attachments.Id,
    attachment_shelf_hold,
    attachment_modal_close,
    attachment_modal_hold,
};

pub const Cursor = @import("Cursor.zig");

// Worst case is 64 visible agent cards plus a one-row scrollbar target for
// every flattened row, one segment per open workspace in the top bar and two
// targets for each visible notification.
// The fixed table keeps the input path allocation-free.
pub const Hits = ui.Hits(Action, 704);

pub const IconDraw = @import("IconDraw.zig");

pub const Context = @import("Context.zig");

test "Nerd Font icons retain a cell fallback and publish a graphical mark" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 4, 1);
    defer buffer.deinit();
    var hits: Hits = .{};
    var plan: icons.Plan = .{};
    var context: Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme.default_theme.palette,
        .hovered = null,
        .icon_theme = .nerd_font,
        .icon_plan = &plan,
    };
    const style: ui.Style = .{
        .fg = .{ .rgb = .{ 1, 2, 3 } },
        .bg = .{ .rgb = .{ 4, 5, 6 } },
    };
    try std.testing.expectEqual(@as(u16, 1), context.drawIcon(.{
        .area = buffer.area(),
        .point = .{ .x = 1, .y = 0 },
        .icon = .cpu,
        .style = style,
    }));
    try std.testing.expectEqualStrings("C", buffer.at(1, 0).?.text());
    try std.testing.expectEqual(@as(u8, 1), plan.len);
    try std.testing.expectEqual(icons.Icon.cpu, plan.slice()[0].icon);
}

test "the telar mark stays graphical over a host-provided background" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 4, 1);
    defer buffer.deinit();
    var hits: Hits = .{};
    var plan: icons.Plan = .{};
    var context: Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme.default_theme.palette,
        .hovered = null,
        .icon_theme = .nerd_font,
        .icon_plan = &plan,
    };

    _ = context.drawIcon(.{ .area = buffer.area(), .point = .{ .x = 1, .y = 0 }, .icon = .telar_mark, .style = .{} });
    try std.testing.expectEqual(@as(u8, 1), plan.len);
    try std.testing.expectEqualStrings(" ", buffer.at(1, 0).?.text());
}

test "the telar mark publishes a graphical mark under the Unicode theme too" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 4, 1);
    defer buffer.deinit();
    var hits: Hits = .{};
    var plan: icons.Plan = .{};
    var context: Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme.default_theme.palette,
        .hovered = null,
        .icon_theme = .unicode,
        .icon_plan = &plan,
    };
    const style: ui.Style = .{
        .fg = theme.default_theme.palette.accent,
        .bg = theme.default_theme.palette.panel_bg,
    };

    _ = context.drawIcon(.{ .area = buffer.area(), .point = .{ .x = 1, .y = 0 }, .icon = .telar_mark, .style = style });
    try std.testing.expectEqual(@as(u8, 1), plan.len);
    try std.testing.expectEqual(icons.Icon.telar_mark, plan.slice()[0].icon);
    try std.testing.expectEqualStrings(" ", buffer.at(1, 0).?.text());

    _ = context.drawIcon(.{ .area = buffer.area(), .point = .{ .x = 2, .y = 0 }, .icon = .cpu, .style = style });
    try std.testing.expectEqual(@as(u8, 1), plan.len);
    try std.testing.expectEqualStrings(icons.Icon.cpu.unicodeGlyph(), buffer.at(2, 0).?.text());
}

test "Nerd Font theme keeps Unicode when terminal colors cannot be reproduced" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 4, 1);
    defer buffer.deinit();
    var hits: Hits = .{};
    var plan: icons.Plan = .{};
    var context: Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme.default_theme.palette,
        .hovered = null,
        .icon_theme = .nerd_font,
        .icon_plan = &plan,
    };
    _ = context.drawIcon(.{ .area = buffer.area(), .point = .{ .x = 1, .y = 0 }, .icon = .cpu, .style = .{} });
    try std.testing.expectEqualStrings("\u{2699}", buffer.at(1, 0).?.text());
    try std.testing.expectEqual(@as(u8, 0), plan.len);
}

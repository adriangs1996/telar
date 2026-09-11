//! Frame-scoped widget dependencies and semantic UI actions.

const PaneIdType = @import("telar-core").PaneId;
const TabIdType = @import("telar-core").TabId;
const WorkspaceIdType = @import("telar-core").WorkspaceId;
const AgentKeyType = @import("telar-client").AgentKey;
const IdType = @import("telar-client").Id;
const AttachmentsTypesId = @import("telar-client").AttachmentId;
const GenericHits = @import("../ui/GenericHits.zig").Type;
const BufferType = @import("telar-core").Buffer;
const std = @import("std");
const PlanType = @import("../ui/Plan.zig");
const Context = @import("Context.zig");
const theme = @import("../ui/theme_support.zig");
const StyleType = @import("telar-core").Style;
const IconType = @import("telar-client").Icon;

pub const Action = union(enum) {
    toggle_sidebar,
    resize_sidebar,
    focus_pane: PaneIdType,
    select_tab: TabIdType,
    active_workspace,
    select_workspace: WorkspaceIdType,
    toggle_workspace_list,
    sidebar_focus_agent: AgentKeyType,
    sidebar_scroll_to: u16,
    notification_activate: IdType,
    notification_dismiss: IdType,
    attachment_open: AttachmentsTypesId,
    attachment_dismiss: AttachmentsTypesId,
    attachment_shelf_hold,
    attachment_modal_close,
    attachment_modal_hold,
};

// Worst case is 64 visible agent cards plus a one-row scrollbar target for
// every flattened row, one segment per open workspace in the top bar and two
// targets for each visible notification.
// The fixed table keeps the input path allocation-free.
pub const Hits = GenericHits(Action, 704);

test "Nerd Font icons retain a cell fallback and publish a graphical mark" {
    var buffer = try BufferType.init(std.testing.allocator, 4, 1);
    defer buffer.deinit();
    var hits: Hits = .{};
    var plan: PlanType = .{};
    var context: Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme.default_theme.palette,
        .hovered = null,
        .icon_theme = .nerd_font,
        .icon_plan = &plan,
    };
    const style: StyleType = .{
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
    try std.testing.expectEqual(IconType.cpu, plan.slice()[0].icon);
}

test "the telar mark stays graphical over a host-provided background" {
    var buffer = try BufferType.init(std.testing.allocator, 4, 1);
    defer buffer.deinit();
    var hits: Hits = .{};
    var plan: PlanType = .{};
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
    var buffer = try BufferType.init(std.testing.allocator, 4, 1);
    defer buffer.deinit();
    var hits: Hits = .{};
    var plan: PlanType = .{};
    var context: Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme.default_theme.palette,
        .hovered = null,
        .icon_theme = .unicode,
        .icon_plan = &plan,
    };
    const style: StyleType = .{
        .fg = theme.default_theme.palette.accent,
        .bg = theme.default_theme.palette.panel_bg,
    };

    _ = context.drawIcon(.{ .area = buffer.area(), .point = .{ .x = 1, .y = 0 }, .icon = .telar_mark, .style = style });
    try std.testing.expectEqual(@as(u8, 1), plan.len);
    try std.testing.expectEqual(IconType.telar_mark, plan.slice()[0].icon);
    try std.testing.expectEqualStrings(" ", buffer.at(1, 0).?.text());

    _ = context.drawIcon(.{ .area = buffer.area(), .point = .{ .x = 2, .y = 0 }, .icon = .cpu, .style = style });
    try std.testing.expectEqual(@as(u8, 1), plan.len);
    try std.testing.expectEqualStrings(IconType.cpu.unicodeGlyph(), buffer.at(2, 0).?.text());
}

test "Nerd Font theme keeps Unicode when terminal colors cannot be reproduced" {
    var buffer = try BufferType.init(std.testing.allocator, 4, 1);
    defer buffer.deinit();
    var hits: Hits = .{};
    var plan: PlanType = .{};
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

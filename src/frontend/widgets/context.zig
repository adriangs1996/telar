//! Frame-scoped widget dependencies and semantic UI actions.

const std = @import("std");
const core = @import("telar-core");
const ui = @import("../ui/root.zig");
const theme = ui.theme;
const icons = ui.icons;
const notifications = @import("../notifications/root.zig");
const agents = @import("../agents/root.zig");
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

pub const Cursor = struct {
    cursor_x: u16,
    cursor_y: u16,
};

// Worst case is 64 visible agent cards plus a one-row scrollbar target for
// every flattened row, one segment per open workspace in the top bar and two
// targets for each visible notification.
// The fixed table keeps the input path allocation-free.
pub const Hits = ui.Hits(Action, 704);

pub const IconDraw = struct {
    area: ui.Rect,
    point: core.ui.Point,
    icon: icons.Icon,
    style: ui.Style,
    /// Cells the graphical mark may span sideways. The fallback glyph still
    /// takes the first cell only; the caller blanks the rest.
    columns: u16 = 1,
};

/// Widgets receive no client state and cannot mutate navigation, layout,
/// transport, or runtime models.
pub const Context = struct {
    buffer: *ui.Buffer,
    hits: *Hits,
    palette: *const theme.Palette,
    hovered: ?Action,
    icon_theme: icons.Theme = .unicode,
    icon_plan: ?*icons.Plan = null,

    pub fn isHovered(context: *const Context, action: Action) bool {
        const hovered = context.hovered orelse return false;
        return std.meta.eql(hovered, action);
    }

    /// Draws the one-cell fallback and, when possible, records an opaque KGP
    /// replacement. Indexed and terminal-default colors stay cell-rendered
    /// because the client cannot reproduce colors it does not know.
    /// For example: `_ = context.drawIcon(.{ .area = area, .point = point, .icon = .cpu, .style = style });`.
    pub fn drawIcon(context: *Context, draw: IconDraw) u16 {
        // The telar mark is artwork with its own alpha: it takes the graphical
        // plan under every icon theme and needs no reproducible colors. Glyph
        // icons need the theme and an RGB pair for their opaque slot.
        const artwork = draw.icon == .telar_mark;
        const requested = if (context.icon_theme == .nerd_font or artwork) context.icon_plan else null;
        const foreground = switch (draw.style.fg) {
            .rgb => |value| value,
            else => null,
        };
        const background = switch (draw.style.bg) {
            .rgb => |value| value,
            else => null,
        };
        const graphical = requested != null and (artwork or (foreground != null and background != null));
        const fallback = if (graphical) draw.icon.cellFallbackGlyph() else draw.icon.unicodeGlyph();
        const written = context.buffer.writeText(draw.area, .{ .point = draw.point, .text = fallback, .style = draw.style });
        if (written != 1 or !graphical) {
            return written;
        }
        const last_x = draw.point.x + @max(draw.columns, 1) - 1;
        if (!draw.area.contains(draw.point.x, draw.point.y) or !draw.area.contains(last_x, draw.point.y) or
            !context.buffer.clip.contains(draw.point.x, draw.point.y) or !context.buffer.clip.contains(last_x, draw.point.y))
        {
            return written;
        }
        requested.?.add(.{
            .area = .{ .x = draw.point.x, .y = draw.point.y, .w = @max(draw.columns, 1), .h = 1 },
            .icon = draw.icon,
            .foreground = foreground orelse @splat(0),
            .background = background orelse @splat(0),
        });
        return written;
    }
};

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

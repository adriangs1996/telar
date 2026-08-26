//! Frame-scoped widget dependencies and semantic UI actions.

const std = @import("std");
const core = @import("telar-core");
const ui = @import("../ui/root.zig");
const theme = ui.theme;
const icons = ui.icons;
const notification = @import("notification.zig");
const sidebar_model = @import("sidebar_model.zig");
const attachments = @import("../attachments/root.zig");

const schema = core.schema;

pub const Action = union(enum) {
    toggle_sidebar,
    focus_pane: schema.PaneId,
    select_tab: schema.TabId,
    active_workspace,
    select_workspace: schema.WorkspaceId,
    toggle_workspace_list,
    sidebar_focus_agent: sidebar_model.AgentKey,
    sidebar_scroll_to: u16,
    notification_activate: notification.Id,
    notification_dismiss: notification.Id,
    attachment_open: attachments.Id,
    attachment_dismiss: attachments.Id,
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
    pub fn drawIcon(
        context: *Context,
        area: ui.Rect,
        x: u16,
        y: u16,
        icon: icons.Icon,
        style: ui.Style,
    ) u16 {
        const requested = if (context.icon_theme == .nerd_font) context.icon_plan else null;
        const foreground = switch (style.fg) {
            .rgb => |value| value,
            else => null,
        };
        const background = switch (style.bg) {
            .rgb => |value| value,
            else => null,
        };
        const graphical = requested != null and foreground != null and background != null;
        const fallback = if (graphical) icon.cellFallbackGlyph() else icon.unicodeGlyph();
        const written = context.buffer.writeText(area, x, y, fallback, style);
        if (written != 1 or !graphical) return written;
        if (!area.contains(x, y) or !context.buffer.clip.contains(x, y)) return written;
        requested.?.add(.{
            .area = .{ .x = x, .y = y, .w = 1, .h = 1 },
            .icon = icon,
            .foreground = foreground.?,
            .background = background.?,
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
    try std.testing.expectEqual(@as(u16, 1), context.drawIcon(
        buffer.area(),
        1,
        0,
        .cpu,
        style,
    ));
    try std.testing.expectEqualStrings("C", buffer.at(1, 0).?.text());
    try std.testing.expectEqual(@as(u8, 1), plan.len);
    try std.testing.expectEqual(icons.Icon.cpu, plan.slice()[0].icon);
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
    _ = context.drawIcon(buffer.area(), 1, 0, .cpu, .{});
    try std.testing.expectEqualStrings("\u{2699}", buffer.at(1, 0).?.text());
    try std.testing.expectEqual(@as(u8, 0), plan.len);
}

const data = @import("model");
const core = @import("telar-core");
const client = @import("telar-client");
const std = @import("std");
const tab_bar = @import("tab_bar.zig");
const Context = @import("Context.zig");
const Plan = @import("../ui/Plan.zig");
const widget = @import("context_support.zig");
/// A tab's shortcut, optional application icon, name and fullscreen marker.
const Label = @This();

buffer: [core.max_tab_label_bytes + 32]u8 = undefined,
len: usize = 0,
fullscreen: bool,
icon: ?data.icons.Icon = null,
icon_column: u16 = 0,

/// Labels tab `slot`; `slot` is also its shortcut position.
/// Example: `const label = Label.init(model, slot);`
pub fn init(model: *const data.ClientModel, slot: usize) Label {
    var label: Label = .{
        .fullscreen = model.tabs.layout[slot].isFullscreen(),
        .icon = data.tab_label.icon(model, slot),
    };
    label.setText(data.tab_label.text(model, slot), slot);

    return label;
}

fn setText(self: *Label, name: []const u8, index: usize) void {
    const prefix = std.fmt.bufPrint(&self.buffer, " {d}:", .{index + 1}) catch unreachable;
    self.icon_column = @intCast(prefix.len);
    const suffix = std.fmt.bufPrint(self.buffer[prefix.len..], "{s}{s} ", .{
        if (self.icon != null) "  " else "",
        name,
    }) catch unreachable;
    self.len = prefix.len + suffix.len;
}

fn text(self: *const Label) []const u8 {
    return self.buffer[0..self.len];
}

pub fn width(self: *const Label) u16 {
    const marker: u16 = if (self.fullscreen) tab_bar.fullscreen_marker_width else 0;
    return core.measure(self.text()) + marker;
}

/// Draws clipped text and icons only when their slots fit. Example: label.draw(context, placement);
pub fn draw(self: *const Label, context: *Context, placement: Placement) void {
    const rect = placement.rect;
    const text_width = @min(core.measure(self.text()), rect.w);
    _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = rect.x, .y = rect.y }, .text = self.text(), .max_width = text_width, .style = placement.style });

    if (self.icon) |icon| {
        if (rect.w > self.icon_column + 1) {
            _ = context.drawIcon(.{ .area = rect, .point = .{ .x = rect.x + self.icon_column, .y = rect.y }, .icon = icon, .style = placement.style });
        }
    }

    if (!self.fullscreen or rect.w < text_width + tab_bar.fullscreen_marker_width) {
        return;
    }

    const marker_x = rect.x + text_width;
    _ = context.drawIcon(.{ .area = rect, .point = .{ .x = marker_x, .y = rect.y }, .icon = .pane_fullscreen, .style = placement.style });
    _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = marker_x + 1, .y = rect.y }, .text = " ", .max_width = 1, .style = placement.style });
}

fn testingModel(label: []const u8) !data.ClientModel {
    var model = data.ClientModel.init(std.testing.allocator, true);
    errdefer model.deinit();
    try data.workspace_handoff.bootstrap(&model, .{
        .pane_id = @enumFromInt(1),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(45) },
        .size = .{ .cols = 8, .rows = 2 },
    });
    model.tabs.setLabel(0, label);
    return model;
}

test "automatic tab labels draw the application icon while manual labels retain their text" {
    var model = try testingModel("");
    defer model.deinit();
    _ = model.panes.find(@enumFromInt(1)).?.setForegroundName("nvim");
    const automatic = Label.init(&model, 0);
    try std.testing.expectEqualStrings(" 1:  nvim ", automatic.text());
    try std.testing.expectEqual(@as(u16, 10), automatic.width());

    var buffer = try core.Buffer.init(std.testing.allocator, 30, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var plan: Plan = .{};
    var context: Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &data.theme_support.default_theme.palette,
        .hovered = null,
        .icon_plan = &plan,
    };
    const placement: Placement = .{
        .rect = .{ .x = 2, .y = 0, .w = automatic.width(), .h = 1 },
        .style = .{ .fg = .rgb(.{ 220, 220, 220 }), .bg = .rgb(.{ 30, 30, 30 }) },
    };
    automatic.draw(&context, placement);
    try std.testing.expectEqualStrings(data.icons.Icon.app_editor.unicodeGlyph(), buffer.at(5, 0).?.text());
    try std.testing.expectEqualStrings("n", buffer.at(7, 0).?.text());
    try std.testing.expectEqual(@as(u8, 0), plan.len);

    context.icon_theme = .nerd_font;
    automatic.draw(&context, placement);
    try std.testing.expectEqual(@as(u8, 1), plan.len);
    try std.testing.expectEqual(data.icons.Icon.app_editor, plan.slice()[0].icon);
    try std.testing.expectEqual(@as(u16, 5), plan.slice()[0].area.x);

    model.tabs.setLabel(0, "My editor");
    _ = model.panes.find(@enumFromInt(1)).?.setForegroundName("git");
    const manual = Label.init(&model, 0);
    try std.testing.expectEqualStrings(" 1:My editor ", manual.text());
    plan.reset();
    buffer.clear(.{});
    manual.draw(&context, .{ .rect = .{ .x = 2, .y = 0, .w = manual.width(), .h = 1 }, .style = placement.style });
    try std.testing.expectEqual(@as(u8, 0), plan.len);
    try std.testing.expectEqualStrings("M", buffer.at(5, 0).?.text());
}

test "tab application icons remain within clipped labels" {
    var model = try testingModel("");
    defer model.deinit();
    const label = Label.init(&model, 0);
    var buffer = try core.Buffer.init(std.testing.allocator, 30, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var plan: Plan = .{};
    var context: Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &data.theme_support.default_theme.palette,
        .hovered = null,
        .icon_theme = .nerd_font,
        .icon_plan = &plan,
    };
    for (0..label.width() + 1) |width_value| {
        const available: u16 = @intCast(width_value);
        buffer.fill(.{ .x = 0, .y = 0, .w = 30, .h = 1 }, .{ .glyph = "." });
        plan.reset();
        label.draw(&context, .{
            .rect = .{ .x = 2, .y = 0, .w = available, .h = 1 },
            .style = .{ .fg = .rgb(.{ 220, 220, 220 }), .bg = .rgb(.{ 30, 30, 30 }) },
        });
        try std.testing.expectEqualStrings(".", buffer.at(1, 0).?.text());
        try std.testing.expectEqualStrings(".", buffer.at(2 + available, 0).?.text());
        try std.testing.expectEqual(@as(u8, if (available >= 5) 1 else 0), plan.len);
    }
}

const Placement = struct {
    rect: core.Rect,
    style: core.Style,
};

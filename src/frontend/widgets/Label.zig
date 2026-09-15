const max_tab_label_bytes_module = @import("telar-core").max_tab_label_bytes;
const TabType = @import("telar-client").Tab;
const MultiplexerModel = @import("telar-client").MultiplexerModel;
const IconType = @import("telar-client").Icon;
const std = @import("std");
const tab_bar = @import("tab_bar.zig");
const measure_module = @import("telar-core").measure;
const ContextType = @import("Context.zig");
const Placement = @import("Placement.zig");
const BufferType = @import("telar-core").Buffer;
const PlanType = @import("../ui/Plan.zig");
const widget = @import("context_support.zig");
const theme = @import("telar-client").theme_support;
/// A tab's shortcut, optional application icon, name and fullscreen marker.
const Label = @This();

buffer: [max_tab_label_bytes_module + 32]u8 = undefined,
len: usize = 0,
fullscreen: bool,
icon: ?IconType = null,
icon_column: u16 = 0,

pub fn init(tab: *const TabType, index: usize) Label {
    var label: Label = .{
        .fullscreen = tab.model.layout.isFullscreen(),
        .icon = tab.labelIcon(),
    };
    label.setText(tab.labelSlice(), index);

    return label;
}

/// Uses the focused application before the tab collection arrives. Example: const label = Label.initModel(model);
pub fn initModel(model: *const MultiplexerModel) Label {
    const pane = model.focusedPaneConst();
    var label: Label = .{
        .fullscreen = model.layout.isFullscreen(),
        .icon = if (pane) |value| value.applicationIcon() else .app_terminal,
    };
    label.setText(if (pane) |value| value.applicationLabel() else "shell", null);

    return label;
}

fn setText(label: *Label, name: []const u8, index: ?usize) void {
    const prefix = if (index) |value|
        std.fmt.bufPrint(&label.buffer, " {d}:", .{value + 1}) catch unreachable
    else
        std.fmt.bufPrint(&label.buffer, " ", .{}) catch unreachable;
    label.icon_column = @intCast(prefix.len);
    const suffix = std.fmt.bufPrint(label.buffer[prefix.len..], "{s}{s} ", .{
        if (label.icon != null) "  " else "",
        name,
    }) catch unreachable;
    label.len = prefix.len + suffix.len;
}

fn text(label: *const Label) []const u8 {
    return label.buffer[0..label.len];
}

pub fn width(label: *const Label) u16 {
    const marker: u16 = if (label.fullscreen) tab_bar.fullscreen_marker_width else 0;
    return measure_module(label.text()) + marker;
}

/// Draws clipped text and icons only when their slots fit. Example: label.draw(context, placement);
pub fn draw(label: *const Label, context: *ContextType, placement: Placement) void {
    const rect = placement.rect;
    const text_width = @min(measure_module(label.text()), rect.w);
    _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = rect.x, .y = rect.y }, .text = label.text(), .max_width = text_width, .style = placement.style });

    if (label.icon) |icon| {
        if (rect.w > label.icon_column + 1) {
            _ = context.drawIcon(.{ .area = rect, .point = .{ .x = rect.x + label.icon_column, .y = rect.y }, .icon = icon, .style = placement.style });
        }
    }

    if (!label.fullscreen or rect.w < text_width + tab_bar.fullscreen_marker_width) {
        return;
    }

    const marker_x = rect.x + text_width;
    _ = context.drawIcon(.{ .area = rect, .point = .{ .x = marker_x, .y = rect.y }, .icon = .pane_fullscreen, .style = placement.style });
    _ = context.buffer.writeTruncated(rect, .{ .point = .{ .x = marker_x + 1, .y = rect.y }, .text = " ", .max_width = 1, .style = placement.style });
}

test "automatic tab labels draw the application icon while manual labels retain their text" {
    var tab = TabType.init(std.testing.allocator, .{
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(45) },
        .label = "",
        .pane_gaps = true,
    });
    defer tab.deinit();
    try tab.model.addRoot(.{
        .pane_id = @enumFromInt(1),
        .location = tab.location,
        .size = .{ .cols = 8, .rows = 2 },
    });
    _ = tab.model.focusedPane().?.setForegroundName("nvim");
    const automatic = Label.init(&tab, 1);
    try std.testing.expectEqualStrings(" 2:  nvim ", automatic.text());
    try std.testing.expectEqual(@as(u16, 10), automatic.width());

    var buffer = try BufferType.init(std.testing.allocator, 30, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var plan: PlanType = .{};
    var context: ContextType = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme.default_theme.palette,
        .hovered = null,
        .icon_plan = &plan,
    };
    const placement: Placement = .{
        .rect = .{ .x = 2, .y = 0, .w = automatic.width(), .h = 1 },
        .style = .{ .fg = .{ .rgb = .{ 220, 220, 220 } }, .bg = .{ .rgb = .{ 30, 30, 30 } } },
    };
    automatic.draw(&context, placement);
    try std.testing.expectEqualStrings(IconType.app_editor.unicodeGlyph(), buffer.at(5, 0).?.text());
    try std.testing.expectEqualStrings("n", buffer.at(7, 0).?.text());
    try std.testing.expectEqual(@as(u8, 0), plan.len);

    context.icon_theme = .nerd_font;
    automatic.draw(&context, placement);
    try std.testing.expectEqual(@as(u8, 1), plan.len);
    try std.testing.expectEqual(IconType.app_editor, plan.slice()[0].icon);
    try std.testing.expectEqual(@as(u16, 5), plan.slice()[0].area.x);

    tab.setLabel("My editor");
    _ = tab.model.focusedPane().?.setForegroundName("git");
    const manual = Label.init(&tab, 1);
    try std.testing.expectEqualStrings(" 2:My editor ", manual.text());
    plan.reset();
    buffer.clear(.{});
    manual.draw(&context, .{ .rect = .{ .x = 2, .y = 0, .w = manual.width(), .h = 1 }, .style = placement.style });
    try std.testing.expectEqual(@as(u8, 0), plan.len);
    try std.testing.expectEqualStrings("M", buffer.at(5, 0).?.text());
}

test "tab application icons remain within clipped labels" {
    var tab = TabType.init(std.testing.allocator, .{
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(45) },
        .label = "",
        .pane_gaps = true,
    });
    defer tab.deinit();
    const label = Label.init(&tab, 0);
    var buffer = try BufferType.init(std.testing.allocator, 30, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var plan: PlanType = .{};
    var context: ContextType = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme.default_theme.palette,
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
            .style = .{ .fg = .{ .rgb = .{ 220, 220, 220 } }, .bg = .{ .rgb = .{ 30, 30, 30 } } },
        });
        try std.testing.expectEqualStrings(".", buffer.at(1, 0).?.text());
        try std.testing.expectEqualStrings(".", buffer.at(2 + available, 0).?.text());
        try std.testing.expectEqual(@as(u8, if (available >= 5) 1 else 0), plan.len);
    }
}

test "tab label fallback uses the foreground application before collection metadata arrives" {
    var model = MultiplexerModel.init(std.testing.allocator);
    defer model.deinit();
    const pending = Label.initModel(&model);
    try std.testing.expectEqualStrings("   shell ", pending.text());
    try std.testing.expectEqual(IconType.app_terminal, pending.icon.?);

    try model.addRoot(.{
        .pane_id = @enumFromInt(1),
        .location = .{ .workspace = .{ .workspace = @enumFromInt(1) }, .tab_id = @enumFromInt(45) },
        .size = .{ .cols = 8, .rows = 2 },
    });
    _ = model.focusedPane().?.setForegroundName("git");
    const label = Label.initModel(&model);
    try std.testing.expectEqualStrings("   git ", label.text());
    try std.testing.expectEqual(IconType.app_git, label.icon.?);
    try std.testing.expectEqual(label.width(), tab_bar.desiredWidth(.{
        .tabs = null,
        .model = &model,
        .area = .{ .x = 0, .y = 0, .w = 30, .h = 1 },
    }));
}

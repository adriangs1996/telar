//! Pane labels drawn inside the fullscreen border, in layout display order.

const BufferType = @import("telar-core").Buffer;
const Input = @import("Input.zig");
const Result = @import("Result.zig");
const std = @import("std");
const max_panes_per_tab_module = @import("telar-core").max_panes_per_tab;
const Label = @import("Label.zig");
const RectType = @import("telar-core").Rect;
const StyleType = @import("telar-core").Style;
const theme = @import("telar-client").theme_support;
const GraphemeIteratorType = @import("telar-core").GraphemeIterator;

/// Shrinks labels before hiding panes. The active label stays visible and
/// earlier labels join it while they fit. Reports the occupied border width
/// and owned label text for optional small-font graphical rendering.
/// No state or allocation survives a draw; focus and resize rebuild the strip.
///
/// ```zig
/// const used = fullscreen_tabs.draw(buffer, input);
/// ```
pub fn draw(buffer: *BufferType, input: Input) Result {
    if (input.area.w == 0 or input.area.h == 0 or input.names.len == 0) {
        return .{};
    }

    std.debug.assert(input.names.len <= max_panes_per_tab_module);
    std.debug.assert(input.focused < input.names.len);
    var result: Result = .{ .plan = .{ .area = input.area } };
    var plan_usable = true;
    var labels: [max_panes_per_tab_module]Label = undefined;
    var total: u16 = @intCast(input.names.len - 1);

    for (input.names, 0..) |name, index| {
        labels[index] = Label.init(name, index);
        total += labels[index].width;
    }

    const count: u16 = @intCast(input.names.len);
    const limit = if (total <= input.area.w)
        input.area.w
    else
        @min(input.area.w, @max(6, (input.area.w -| (count - 1)) / count));

    for (labels[0..input.names.len]) |*label| {
        label.width = @min(label.width, limit);
    }

    var first = input.focused;
    var used = labels[first].width;

    while (first > 0) {
        const width = labels[first - 1].width + 1;
        if (width > input.area.w - used) {
            break;
        }

        first -= 1;
        used += width;
    }

    used = 0;

    for (labels[first..input.names.len], first..) |*label, index| {
        if (index != first) {
            used += 1;
        }

        if (used >= input.area.w) {
            break;
        }

        const width = @min(label.width, input.area.w - used);
        const rect: RectType = .{ .x = input.area.x + used, .y = input.area.y, .w = width, .h = 1 };
        const style: StyleType = if (index == input.focused)
            .{ .fg = input.palette.surface_dim, .bg = input.palette.accent }
        else
            .{ .fg = input.palette.subtext0 };
        buffer.fill(rect, .{ .glyph = " ", .style = style });
        _ = buffer.writeTruncated(rect, .{
            .point = .{ .x = rect.x, .y = rect.y },
            .text = label.buffer[0..label.len],
            .max_width = rect.w,
            .style = style,
        });
        plan_usable = result.plan.appendPainted(.{ .buffer = buffer, .area = rect, .selected = index == input.focused }) and plan_usable;

        used += width;
    }

    result.width = @min(used, input.area.w);
    result.plan.area.w = result.width;
    if (!plan_usable) {
        result.plan = .{};
    }

    return result;
}

test "fullscreen tabs label every pane and highlight only the focused pane" {
    var buffer = try BufferType.init(std.testing.allocator, 40, 1);
    defer buffer.deinit();
    buffer.fill(buffer.area(), .{ .glyph = "─", .style = .{} });
    const palette = &theme.default_theme.palette;
    const used = draw(&buffer, .{
        .area = buffer.area(),
        .names = &.{ "nvim", "claude", "" },
        .focused = 1,
        .palette = palette,
    });

    const expected = " 1 nvim ─ 2 claude ─ 3 shell ";
    var clusters: GraphemeIteratorType = .{ .bytes = expected };
    var x: u16 = 0;
    while (clusters.next()) |cluster| : (x += cluster.width) {
        try std.testing.expectEqualStrings(cluster.bytes, buffer.at(x, 0).?.text());
    }

    try std.testing.expectEqual(x, used.width);
    for (buffer.cells, 0..) |cell, index| {
        const focused = index >= 9 and index < 19;
        try std.testing.expectEqual(focused, std.meta.eql(cell.style.bg, palette.accent));
        try std.testing.expect(!cell.style.flags.bold);
    }
}

test "fullscreen tabs keep focus visible at every width within fixed pane bounds" {
    var buffer = try BufferType.init(std.testing.allocator, 82, 3);
    defer buffer.deinit();
    const palette = &theme.default_theme.palette;
    const names = [_][]const u8{"long-foreground-process-name"} ** max_panes_per_tab_module;
    for (0..names.len) |focused| {
        for (0..79) |width| {
            buffer.fill(buffer.area(), .{ .glyph = ".", .style = .{} });
            const area: RectType = .{ .x = 2, .y = 1, .w = @intCast(width), .h = 1 };
            const used = draw(&buffer, .{ .area = area, .names = &names, .focused = focused, .palette = palette });
            try std.testing.expect(used.width <= width);
            var selected_cells: usize = 0;
            for (buffer.cells, 0..) |cell, index| {
                const x = index % buffer.w;
                const y = index / buffer.w;
                if (y != area.y or x < area.x or x >= area.x + area.w) {
                    try std.testing.expectEqualStrings(".", cell.text());
                    continue;
                }

                if (std.meta.eql(cell.style.bg, palette.accent)) {
                    selected_cells += 1;
                }
            }

            try std.testing.expectEqual(width != 0, selected_cells > 0);
        }
    }
}

test "fullscreen label plans retain bounded truncated Unicode text" {
    var buffer = try BufferType.init(std.testing.allocator, 84, 3);
    defer buffer.deinit();
    const names: []const []const u8 = &.{ "long-process-name", "界界界界界", "e\u{301}ditor-long" };
    for (0..names.len) |focused| {
        for (0..80) |width| {
            buffer.clear(.{});
            const area: RectType = .{ .x = 2, .y = 1, .w = @intCast(width), .h = 1 };
            const result = draw(&buffer, .{
                .area = area,
                .names = names,
                .focused = focused,
                .palette = &theme.default_theme.palette,
            });
            try std.testing.expect(result.width <= width);
            var selected: usize = 0;
            for (result.plan.slice()) |*label| {
                try std.testing.expect(std.unicode.utf8ValidateSlice(label.text()));
                try std.testing.expect(label.offset + label.width <= result.plan.area.w);
                selected += @intFromBool(label.selected);
            }

            try std.testing.expectEqual(@as(usize, if (width == 0) 0 else 1), selected);
        }
    }
}

test "fullscreen tabs truncate Unicode names at grapheme boundaries" {
    var buffer = try BufferType.init(std.testing.allocator, 17, 1);
    defer buffer.deinit();
    _ = draw(&buffer, .{
        .area = buffer.area(),
        .names = &.{ "界界界界界", "e\u{301}ditor-long" },
        .focused = 1,
        .palette = &theme.default_theme.palette,
    });

    try std.testing.expectEqualStrings("界", buffer.at(3, 0).?.text());
    try std.testing.expectEqualStrings("…", buffer.at(7, 0).?.text());
    try std.testing.expectEqualStrings("e\u{301}", buffer.at(12, 0).?.text());
    try std.testing.expectEqualStrings("…", buffer.at(16, 0).?.text());
}

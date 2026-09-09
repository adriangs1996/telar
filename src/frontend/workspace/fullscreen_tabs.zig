//! Pane labels drawn inside the fullscreen border, in layout display order.

const std = @import("std");
const core = @import("telar-core");
const theme = @import("../ui/root.zig").theme;
const ui = core.ui;
const schema = core.schema;

pub const Input = struct {
    area: ui.Rect,
    names: []const []const u8,
    focused: usize,
    palette: *const theme.Palette,
};

const Label = struct {
    buffer: [schema.max_foreground_name_bytes + 32]u8 = undefined,
    len: usize,
    width: u16,

    fn init(name: []const u8, index: usize) Label {
        var label: Label = .{ .len = 0, .width = 0 };
        const text = std.fmt.bufPrint(&label.buffer, " {d} {s} ", .{
            index + 1,
            if (name.len == 0) "shell" else name,
        }) catch unreachable;
        label.len = text.len;
        label.width = ui.measure(text);
        return label;
    }
};

/// Shrinks labels before hiding panes. The active label stays visible and
/// earlier labels join it while they fit. Returns the occupied border width.
/// No state or allocation survives a draw; focus and resize rebuild the strip.
///
/// ```zig
/// const used = fullscreen_tabs.draw(buffer, input);
/// ```
pub fn draw(buffer: *ui.Buffer, input: Input) u16 {
    if (input.area.w == 0 or input.area.h == 0 or input.names.len == 0) {
        return 0;
    }

    std.debug.assert(input.names.len <= schema.max_panes_per_tab);
    std.debug.assert(input.focused < input.names.len);
    var labels: [schema.max_panes_per_tab]Label = undefined;
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
        const rect: ui.Rect = .{ .x = input.area.x + used, .y = input.area.y, .w = width, .h = 1 };
        const style: ui.Style = if (index == input.focused)
            .{ .fg = input.palette.surface_dim, .bg = input.palette.accent, .flags = .{ .bold = true } }
        else
            .{ .fg = input.palette.subtext0 };
        buffer.fill(rect, .{ .glyph = " ", .style = style });
        _ = buffer.writeTruncated(rect, .{
            .point = .{ .x = rect.x, .y = rect.y },
            .text = label.buffer[0..label.len],
            .max_width = width,
            .style = style,
        });
        used += width;
    }

    return @min(used, input.area.w);
}

test "fullscreen tabs label every pane and highlight only the focused pane" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 40, 1);
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
    var clusters: ui.GraphemeIterator = .{ .bytes = expected };
    var x: u16 = 0;
    while (clusters.next()) |cluster| : (x += cluster.width) {
        try std.testing.expectEqualStrings(cluster.bytes, buffer.at(x, 0).?.text());
    }

    try std.testing.expectEqual(x, used);
    for (buffer.cells, 0..) |cell, index| {
        const focused = index >= 9 and index < 19;
        try std.testing.expectEqual(focused, std.meta.eql(cell.style.bg, palette.accent));
        try std.testing.expectEqual(focused, cell.style.flags.bold);
    }
}

test "fullscreen tabs keep focus visible at every width within fixed pane bounds" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 82, 3);
    defer buffer.deinit();
    const palette = &theme.default_theme.palette;
    const names = [_][]const u8{"long-foreground-process-name"} ** schema.max_panes_per_tab;
    for (0..names.len) |focused| {
        for (0..79) |width| {
            buffer.fill(buffer.area(), .{ .glyph = ".", .style = .{} });
            const area: ui.Rect = .{ .x = 2, .y = 1, .w = @intCast(width), .h = 1 };
            const used = draw(&buffer, .{ .area = area, .names = &names, .focused = focused, .palette = palette });
            try std.testing.expect(used <= width);
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

test "fullscreen tabs truncate Unicode names at grapheme boundaries" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 17, 1);
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

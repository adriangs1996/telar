const ContextType = @import("Context.zig");
const HistoryBrowserInput = @import("HistoryBrowserInput.zig");
const ColorType = @import("telar-core").Color;
const RectType = @import("telar-core").Rect;
const Text = @import("Text.zig");
const history_browser = @import("history_browser.zig");
const std = @import("std");
const GraphemeIteratorType = @import("telar-core").GraphemeIterator;
const Entry = @import("Entry.zig");
const Inspection = @import("Inspection.zig");
const Wrapped = @import("Wrapped.zig");
const Detail = @import("Detail.zig");
const Drawing = @This();

context: *ContextType,
input: HistoryBrowserInput,
background: ColorType,

pub fn line(draw: *Drawing, area: RectType, value: Text) void {
    _ = draw.context.buffer.writeTruncated(area, .{ .point = .{ .x = area.x, .y = area.y }, .text = value.text, .max_width = area.w, .style = .{ .fg = value.color, .bg = draw.background } });
}

pub fn rows(draw: *Drawing, area: RectType) void {
    if (draw.input.loading or draw.input.entries.len == 0) {
        draw.line(area, .{ .text = if (draw.input.loading) "Searching..." else "No matching commands", .color = draw.context.palette.subtext0 });
        return;
    }

    const selected = @min(draw.input.selection, draw.input.entries.len - 1);
    const count = @min(area.h, draw.input.entries.len);
    const start = if (selected >= count) selected + 1 - count else 0;
    for (0..count) |offset| {
        const index = start + offset;
        const entry = draw.input.entries[index];
        const row: RectType = .{ .x = area.x, .y = area.y + area.h - 1 - @as(u16, @intCast(offset)), .w = area.w, .h = 1 };
        draw.background = if (index == selected) draw.context.palette.surface1 else draw.context.palette.panel_bg;
        draw.context.buffer.fill(row, .{ .glyph = " ", .style = .{ .bg = draw.background } });
        draw.line(row, .{ .text = if (index == selected) ">" else " ", .color = draw.context.palette.accent });
        var x = row.x + 2;
        var storage: [32]u8 = undefined;
        if (row.w >= 40) {
            const duration = history_browser.durationText(entry.duration_ns, &storage);
            draw.line(.{ .x = x, .y = row.y, .w = 7, .h = 1 }, .{ .text = duration, .color = draw.context.palette.yellow });
            x += 8;
        }

        if (row.w >= 64) {
            const age = history_browser.ageText(draw.input.now_ms -| entry.started_at_ms, &storage);
            draw.line(.{ .x = x, .y = row.y, .w = 7, .h = 1 }, .{ .text = age, .color = draw.context.palette.subtext0 });
            x += 8;
        }

        const failed = entry.exit_code != null and entry.exit_code.? != 0;
        const status = if (entry.status == .running) "run" else if (entry.status == .interrupted) "stop" else if (entry.exit_code) |code| std.fmt.bufPrint(&storage, "{d}", .{code}) catch "?" else "?";
        draw.line(.{ .x = x, .y = row.y, .w = 5, .h = 1 }, .{ .text = status, .color = if (failed) draw.context.palette.red else draw.context.palette.green });
        x += 6;
        draw.command(.{ .x = x, .y = row.y, .w = (row.x + row.w) -| x, .h = 1 }, entry.command);
    }

    draw.background = draw.context.palette.panel_bg;
}

fn command(draw: *Drawing, area: RectType, command_text: []const u8) void {
    draw.line(area, .{ .text = command_text, .color = draw.context.palette.text });
    const query = draw.input.field.text();
    if (query.len == 0) {
        return;
    }

    var iterator: GraphemeIteratorType = .{ .bytes = command_text };
    var x = area.x;
    var matched: usize = 0;
    while (iterator.next()) |cluster| {
        if (@as(u32, x) + cluster.width > @as(u32, area.x) + area.w or matched == query.len) {
            break;
        }

        if (cluster.bytes.len <= query.len - matched and std.ascii.eqlIgnoreCase(cluster.bytes, query[matched..][0..cluster.bytes.len])) {
            draw.line(.{ .x = x, .y = area.y, .w = cluster.width, .h = 1 }, .{ .text = cluster.bytes, .color = draw.context.palette.accent });
            matched += cluster.bytes.len;
        }

        x += cluster.width;
    }
}

pub fn inspect(draw: *Drawing, area: RectType, entry: Entry) void {
    const content: Inspection = .{ .entry = entry, .output = draw.input.output, .output_hint = draw.input.output_hint };
    const scroll = if (draw.input.detail_scroll == 0) 0 else @min(draw.input.detail_scroll, history_browser.detailScrollLimit(area, content));
    var lines: Wrapped = .{ .draw = draw, .area = area, .skip = scroll };
    var detail = Detail.init(content);
    for (detail.texts(), 0..) |text, index| {
        lines.text(.{ .text = text, .color = if (index == 0 or index == 6) draw.context.palette.accent else if (index == 1) draw.context.palette.text else draw.context.palette.subtext0 });
    }
}

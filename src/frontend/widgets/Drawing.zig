const core = @import("telar-core");
const Context = @import("Context.zig");
const HistoryBrowserInput = @import("HistoryBrowserInput.zig");
const Text = @import("Text.zig");
const history_browser = @import("history_browser.zig");
const std = @import("std");
const Entry = @import("Entry.zig");
const Inspection = @import("Inspection.zig");
const Wrapped = @import("Wrapped.zig");
const Detail = @import("Detail.zig");
const Drawing = @This();

context: *Context,
input: HistoryBrowserInput,
background: core.Color,

pub fn line(self: *Drawing, area: core.Rect, value: Text) void {
    _ = self.context.buffer.writeTruncated(area, .{ .point = .{ .x = area.x, .y = area.y }, .text = value.text, .max_width = area.w, .style = .{ .fg = value.color, .bg = self.background } });
}

pub fn rows(self: *Drawing, area: core.Rect) void {
    if (self.input.entries.len == 0) {
        self.line(area, .{ .text = if (self.input.loading) "Searching..." else "No matching commands", .color = self.context.palette.subtext0 });
        return;
    }

    const selected = @min(self.input.selection, self.input.entries.len - 1);
    const count = @min(area.h, self.input.entries.len);
    const start = if (selected >= count) selected + 1 - count else 0;
    for (0..count) |offset| {
        const index = start + offset;
        const entry = self.input.entries[index];
        const row: core.Rect = .{ .x = area.x, .y = area.y + area.h - 1 - @as(u16, @intCast(offset)), .w = area.w, .h = 1 };
        self.background = if (index == selected) self.context.palette.surface1 else self.context.palette.panel_bg;
        self.context.buffer.fill(row, .{ .glyph = " ", .style = .{ .bg = self.background } });
        self.line(row, .{ .text = if (index == selected) ">" else " ", .color = self.context.palette.accent });
        var x = row.x + 2;
        var storage: [32]u8 = undefined;
        if (row.w >= 40) {
            const duration = history_browser.durationText(entry.duration_ns, &storage);
            self.line(.{ .x = x, .y = row.y, .w = 7, .h = 1 }, .{ .text = duration, .color = self.context.palette.yellow });
            x += 8;
        }

        if (row.w >= 64) {
            const age = history_browser.ageText(self.input.now_ms -| entry.started_at_ms, &storage);
            self.line(.{ .x = x, .y = row.y, .w = 7, .h = 1 }, .{ .text = age, .color = self.context.palette.subtext0 });
            x += 8;
        }

        const failed = entry.exit_code != null and entry.exit_code.? != 0;
        const status = if (entry.status == .running) "run" else if (entry.status == .interrupted) "stop" else if (entry.exit_code) |code| std.fmt.bufPrint(&storage, "{d}", .{code}) catch "?" else "?";
        self.line(.{ .x = x, .y = row.y, .w = 5, .h = 1 }, .{ .text = status, .color = if (failed) self.context.palette.red else self.context.palette.green });
        x += 6;
        self.command(.{ .x = x, .y = row.y, .w = (row.x + row.w) -| x, .h = 1 }, entry.command);
    }

    self.background = self.context.palette.panel_bg;
}

fn command(self: *Drawing, area: core.Rect, command_text: []const u8) void {
    self.line(area, .{ .text = command_text, .color = self.context.palette.text });
    const query = self.input.field.text();
    if (query.len == 0) {
        return;
    }

    var iterator: core.GraphemeIterator = .{ .bytes = command_text };
    var x = area.x;
    var matched: usize = 0;
    while (iterator.next()) |cluster| {
        if (@as(u32, x) + cluster.width > @as(u32, area.x) + area.w or matched == query.len) {
            break;
        }

        if (cluster.bytes.len <= query.len - matched and std.ascii.eqlIgnoreCase(cluster.bytes, query[matched..][0..cluster.bytes.len])) {
            self.line(.{ .x = x, .y = area.y, .w = cluster.width, .h = 1 }, .{ .text = cluster.bytes, .color = self.context.palette.accent });
            matched += cluster.bytes.len;
        }

        x += cluster.width;
    }
}

pub fn inspect(self: *Drawing, area: core.Rect, entry: Entry) void {
    const content: Inspection = .{ .entry = entry, .output = self.input.output, .output_hint = self.input.output_hint };
    const scroll = if (self.input.detail_scroll == 0) 0 else @min(self.input.detail_scroll, history_browser.detailScrollLimit(area, content));
    var lines: Wrapped = .{ .draw = self, .area = area, .skip = scroll };
    var detail = Detail.init(content);
    for (detail.texts(), 0..) |text, index| {
        lines.text(.{ .text = text, .color = if (index == 0 or index == 6) self.context.palette.accent else if (index == 1) self.context.palette.text else self.context.palette.subtext0 });
    }
}

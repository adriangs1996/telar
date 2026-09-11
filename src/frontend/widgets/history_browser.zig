//! Compact history browser with bounded text storage and visible-cell composition.
//! History text reaches the host only through the ordinary cell renderer.

const RectType = @import("telar-core").Rect;
const Geometry = @import("Geometry.zig");
const ContextType = @import("Context.zig");
const HistoryBrowserInput = @import("HistoryBrowserInput.zig");
const GotoPickerOutput = @import("GotoPickerOutput.zig");
const Drawing = @import("Drawing.zig");
const StyleType = @import("telar-core").Style;
const std = @import("std");
const Entry = @import("Entry.zig");
const raw_module = @import("telar-core").raw;
const measure_module = @import("telar-core").measure;
const Inspection = @import("Inspection.zig");
const Detail = @import("Detail.zig");
const GraphemeIteratorType = @import("telar-core").GraphemeIterator;
const BufferType = @import("telar-core").Buffer;
const widget = @import("context_support.zig");
const theme_support = @import("../ui/theme_support.zig");
const picker = @import("goto_picker.zig");

/// Computes the same compact rectangle for cell composition and graphical overlays.
/// Example: `const area = modalArea(application, .{ .count = 6, .inspecting = false });`.
pub fn modalArea(application: RectType, geometry: Geometry) RectType {
    if (application.w < 20 or application.h < 7) {
        return .{};
    }

    const width = @min(application.w -| 4, @as(u16, if (geometry.inspecting) 140 else 104));
    const wanted_height: u16 = if (geometry.inspecting) 30 else @min(@max(geometry.count, 1), 16) + 7;
    const height = @min(application.h -| 2, wanted_height);
    return .{
        .x = application.x + (application.w - width) / 2,
        .y = application.y + (application.h - height) / 2,
        .w = width,
        .h = height,
    };
}

/// Draws search, visible rows and optional detail without allocating.
/// Example: `const result = render(context, application, input);`.
pub fn render(context: *ContextType, application: RectType, input: HistoryBrowserInput) GotoPickerOutput {
    const area = modalArea(application, .{ .count = @intCast(input.entries.len), .inspecting = input.inspecting });
    if (area.isEmpty()) {
        return .{ .area = area, .cursor = null };
    }

    var draw: Drawing = .{ .context = context, .input = input, .background = context.palette.panel_bg };
    const base: StyleType = .{ .fg = context.palette.text, .bg = draw.background };
    if (input.graphical_frame) {
        context.buffer.fillWithoutCorners(area, base);
    } else {
        context.buffer.fill(area, .{ .glyph = " ", .style = base });
        context.buffer.box(area, .{ .style = .{ .fg = context.palette.accent, .bg = draw.background } });
    }

    const inner = area.inner(1);
    const title = if (input.match_fuzzy and input.field.text().len != 0) " History | fuzzy: newest 1000 " else " History ";
    draw.line(.{ .x = area.x + 2, .y = area.y, .w = area.w -| 4, .h = 1 }, .{ .text = title, .color = context.palette.accent });
    if (area.w > 40) {
        var count_storage: [48]u8 = undefined;
        const count_text = std.fmt.bufPrint(&count_storage, " {d}-{d}{s} ", .{ input.page_offset + @intFromBool(input.entries.len != 0), input.page_offset + input.entries.len, if (input.has_more) " +more" else "" }) catch "";
        _ = context.buffer.writeRight(.{ .x = area.x + 14, .y = area.y, .w = area.w - 16, .h = 1 }, .{ .y = area.y, .text = count_text, .style = .{ .fg = context.palette.subtext0, .bg = draw.background } });
    }
    const footer_y = inner.y + inner.h - 1;
    const query_y = footer_y - 1;
    const detail_y = query_y - 1;
    const list: RectType = .{ .x = inner.x, .y = inner.y, .w = inner.w, .h = detail_y - inner.y };
    const selected: ?Entry = if (input.entries.len == 0 or input.loading) null else input.entries[@min(input.selection, input.entries.len - 1)];
    if (input.inspecting and selected != null) {
        if (list.w >= 100) {
            const left: RectType = .{ .x = list.x, .y = list.y, .w = list.w / 2, .h = list.h };
            draw.rows(left);
            const right: RectType = .{ .x = left.x + left.w + 1, .y = list.y, .w = list.w - left.w - 1, .h = list.h };
            draw.inspect(right, selected.?);
        } else {
            draw.inspect(list, selected.?);
        }
    } else {
        draw.rows(list);
    }

    var detail_buffer: [512]u8 = undefined;
    const detail = if (input.error_text.len != 0) input.error_text else if (selected) |entry|
        std.fmt.bufPrint(&detail_buffer, "{s}  {s}  pane {d}  #{d}", .{ entry.cwd, @tagName(entry.author), raw_module(entry.pane_id), entry.id }) catch entry.cwd
    else
        "No selection";
    draw.line(.{ .x = inner.x + 1, .y = detail_y, .w = inner.w -| 2, .h = 1 }, .{ .text = detail, .color = if (input.error_text.len == 0) context.palette.subtext0 else context.palette.red });

    var prefix_buffer: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "[{s}] > ", .{input.scope}) catch "> ";
    const query: RectType = .{ .x = inner.x, .y = query_y, .w = inner.w, .h = 1 };
    context.buffer.fill(query, .{ .glyph = " ", .style = .{ .fg = context.palette.text, .bg = context.palette.surface0 } });
    draw.background = context.palette.surface0;
    draw.line(query, .{ .text = prefix, .color = context.palette.accent });
    const prefix_width = @min(measure_module(prefix), query.w);
    const field = input.field.view(query.w -| prefix_width);
    draw.line(.{ .x = query.x + prefix_width, .y = query.y, .w = query.w -| prefix_width, .h = 1 }, .{ .text = field.text, .color = context.palette.text });
    draw.background = context.palette.panel_bg;

    const help = if (input.inspecting and inner.w < 60)
        "^O back  PgUp/PgDn scroll  Esc back"
    else if (inner.w < 60)
        if (input.enter_runs) "Enter run  ^O inspect  Esc back" else "Enter paste  ^O inspect  Esc back"
    else if (input.inspecting)
        "^O back  PgUp/PgDn scroll  Up/Down select  Esc back"
    else if (input.enter_runs)
        "Enter run  Shift+Enter paste  Tab scope  ^O inspect  Esc close"
    else
        "Enter paste  Shift+Enter run  Tab scope  ^O inspect  Esc close";
    draw.line(.{ .x = inner.x + 1, .y = footer_y, .w = inner.w -| 2, .h = 1 }, .{ .text = help, .color = context.palette.subtext0 });
    return .{ .area = area, .cursor = .{ .cursor_x = query.x + prefix_width + field.cursor, .cursor_y = query.y } };
}

/// Bounds scroll against the same wrapped detail and responsive width used for drawing.
/// Example: `const limit = inspectionScrollLimit(application, content);`.
pub fn inspectionScrollLimit(application: RectType, content: Inspection) u32 {
    const area = modalArea(application, .{ .count = 1, .inspecting = true }).inner(1);
    const width = if (area.w >= 100) area.w - area.w / 2 - 1 else area.w;
    return detailScrollLimit(.{ .w = width, .h = area.h -| 3 }, content);
}

pub fn detailScrollLimit(area: RectType, content: Inspection) u32 {
    if (area.w == 0) {
        return 0;
    }

    var detail = Detail.init(content);
    var count: u32 = 0;
    for (detail.texts()) |text| {
        count += 1;
        var iterator: GraphemeIteratorType = .{ .bytes = text };
        var x: u16 = 0;
        while (iterator.next()) |cluster| {
            const newline = iterator.index > 0 and text[iterator.index - 1] == '\n';
            if (newline or @as(u32, x) + cluster.width > area.w) {
                count += 1;
                x = 0;
                if (newline) {
                    continue;
                }
            }

            x += cluster.width;
        }
    }

    return count -| area.h;
}

pub fn durationText(ns: i64, storage: []u8) []const u8 {
    const milliseconds = @divTrunc(@max(ns, 0), std.time.ns_per_ms);
    return if (milliseconds < 1000) std.fmt.bufPrint(storage, "{d}ms", .{milliseconds}) catch "?" else if (milliseconds < 60000) std.fmt.bufPrint(storage, "{d}.{d}s", .{ @divTrunc(milliseconds, 1000), @divTrunc(@mod(milliseconds, 1000), 100) }) catch "?" else if (milliseconds < 3600000) std.fmt.bufPrint(storage, "{d}m", .{@divTrunc(milliseconds, 60000)}) catch "?" else std.fmt.bufPrint(storage, "{d}h", .{@divTrunc(milliseconds, 3600000)}) catch "?";
}

pub fn timestampText(ms: i64, storage: []u8) []const u8 {
    if (ms < 0 or ms > 253402300799999) {
        return "Timestamp unavailable";
    }

    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(ms, 1000)) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    return std.fmt.bufPrint(storage, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ day.year, @intFromEnum(month.month), month.day_index + 1, clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute() }) catch "";
}

pub fn ageText(ms: i64, storage: []u8) []const u8 {
    const seconds = @divTrunc(@max(ms, 0), 1000);
    return if (seconds < 60) "now" else if (seconds < 3600) std.fmt.bufPrint(storage, "{d}m ago", .{@divTrunc(seconds, 60)}) catch "?" else if (seconds < 86400) std.fmt.bufPrint(storage, "{d}h ago", .{@divTrunc(seconds, 3600)}) catch "?" else std.fmt.bufPrint(storage, "{d}d ago", .{@divTrunc(seconds, 86400)}) catch "?";
}

test "compact geometry follows content and remains inside small terminals" {
    const application: RectType = .{ .w = 160, .h = 60 };
    const small = modalArea(application, .{ .count = 3, .inspecting = false });
    const large = modalArea(application, .{ .count = 100, .inspecting = false });
    try std.testing.expect(small.h < large.h);
    try std.testing.expectEqual(@as(u16, 10), small.h);
    try std.testing.expect(large.h < application.h / 2);
    const narrow = modalArea(.{ .w = 24, .h = 8 }, .{ .count = 100, .inspecting = true });
    try std.testing.expect(narrow.x + narrow.w <= 24);
    try std.testing.expect(narrow.y + narrow.h <= 8);
}

test "wrapped inspector clamps scroll even beyond 64 thousand lines" {
    const entry: Entry = .{ .id = 1, .pane_id = @enumFromInt(2), .command = "echo hi", .cwd = "/work", .started_at_ms = -1, .duration_ns = 0, .exit_code = 0, .status = .completed, .author = .human };
    const application: RectType = .{ .w = 56, .h = 20 };
    const limit = inspectionScrollLimit(application, .{ .entry = entry, .output = "a\n" ** 32768, .output_hint = "Captured output" });
    try std.testing.expect(limit > 32700);
    try std.testing.expectEqual(@as(u32, 0), inspectionScrollLimit(application, .{ .entry = entry, .output = "done", .output_hint = "Captured output" }));
    var detail = Detail.init(.{ .entry = entry, .output = "", .output_hint = "" });
    try std.testing.expectEqualStrings("Timestamp unavailable", detail.texts()[4]);
}

test "history renderer puts the query below results and contains control bytes" {
    var buffer = try BufferType.init(std.testing.allocator, 120, 36);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: ContextType = .{ .buffer = &buffer, .hits = &hits, .palette = &theme_support.default_theme.palette, .hovered = null };
    var field: picker.Field = .init("zig");
    const entry: Entry = .{ .id = 1, .pane_id = @enumFromInt(2), .command = "zig build\x1b[2J", .cwd = "/work", .started_at_ms = 1700000000000, .duration_ns = 1800000000, .exit_code = 7, .status = .completed, .author = .human };
    const input: HistoryBrowserInput = .{ .field = &field, .entries = &.{entry}, .selection = 0, .scope = "global", .now_ms = 1700000100000 };
    const result = render(&context, buffer.area(), input);
    try std.testing.expectEqual(result.area.y + result.area.h - 3, result.cursor.?.cursor_y);
    try std.testing.expectEqualStrings(">", buffer.at(result.area.x + 1, result.cursor.?.cursor_y - 2).?.text());
    var inspector = input;
    inspector.inspecting = true;
    inspector.output = "hello\n\x1b]52;c;secret\x07";
    _ = render(&context, buffer.area(), inspector);
    for (0..buffer.area().h) |y| {
        for (0..buffer.area().w) |x| {
            const text = buffer.at(@intCast(x), @intCast(y)).?.text();
            try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x1b) == null);
            try std.testing.expect(std.mem.indexOfScalar(u8, text, 0x07) == null);
        }
    }
}

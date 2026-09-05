//! Compact history browser with bounded text storage and visible-cell composition.
//! History text reaches the host only through the ordinary cell renderer.

const std = @import("std");
const core = @import("telar-core");
const ui = @import("../ui/root.zig");
const widget = @import("context.zig");
const picker = @import("goto_picker.zig");

pub const Entry = struct {
    command: []const u8,
    cwd: []const u8,
    id: u64,
    pane_id: core.schema.PaneId,
    started_at_ms: i64,
    duration_ns: i64,
    exit_code: ?i32,
    status: core.schema.HistoryStatus,
    author: core.schema.HistoryAuthor,
};

pub const Geometry = struct {
    count: u16,
    inspecting: bool,
};

pub const Input = struct {
    field: *picker.Field,
    entries: []const Entry,
    selection: u16,
    scope: []const u8,
    inspecting: bool = false,
    detail_scroll: u32 = 0,
    now_ms: i64 = 0,
    enter_runs: bool = false,
    match_fuzzy: bool = true,
    loading: bool = false,
    error_text: []const u8 = "",
    output: []const u8 = "",
    output_hint: []const u8 = "No captured output",
    graphical_frame: bool = false,
    page_offset: u32 = 0,
    has_more: bool = false,
};

/// Computes the same compact rectangle for cell composition and graphical overlays.
/// Example: `const area = modalArea(application, .{ .count = 6, .inspecting = false });`.
pub fn modalArea(application: ui.Rect, geometry: Geometry) ui.Rect {
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
pub fn render(context: *widget.Context, application: ui.Rect, input: Input) picker.Output {
    const area = modalArea(application, .{ .count = @intCast(input.entries.len), .inspecting = input.inspecting });
    if (area.isEmpty()) {
        return .{ .area = area, .cursor = null };
    }

    var draw: Drawing = .{ .context = context, .input = input, .background = context.palette.panel_bg };
    const base: ui.Style = .{ .fg = context.palette.text, .bg = draw.background };
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
    const list: ui.Rect = .{ .x = inner.x, .y = inner.y, .w = inner.w, .h = detail_y - inner.y };
    const selected: ?Entry = if (input.entries.len == 0 or input.loading) null else input.entries[@min(input.selection, input.entries.len - 1)];
    if (input.inspecting and selected != null) {
        if (list.w >= 100) {
            const left: ui.Rect = .{ .x = list.x, .y = list.y, .w = list.w / 2, .h = list.h };
            draw.rows(left);
            const right: ui.Rect = .{ .x = left.x + left.w + 1, .y = list.y, .w = list.w - left.w - 1, .h = list.h };
            draw.inspect(right, selected.?);
        } else {
            draw.inspect(list, selected.?);
        }
    } else {
        draw.rows(list);
    }

    var detail_buffer: [512]u8 = undefined;
    const detail = if (input.error_text.len != 0) input.error_text else if (selected) |entry|
        std.fmt.bufPrint(&detail_buffer, "{s}  {s}  pane {d}  #{d}", .{ entry.cwd, @tagName(entry.author), core.schema.id.raw(entry.pane_id), entry.id }) catch entry.cwd
    else
        "No selection";
    draw.line(.{ .x = inner.x + 1, .y = detail_y, .w = inner.w -| 2, .h = 1 }, .{ .text = detail, .color = if (input.error_text.len == 0) context.palette.subtext0 else context.palette.red });

    var prefix_buffer: [48]u8 = undefined;
    const prefix = std.fmt.bufPrint(&prefix_buffer, "[{s}] > ", .{input.scope}) catch "> ";
    const query: ui.Rect = .{ .x = inner.x, .y = query_y, .w = inner.w, .h = 1 };
    context.buffer.fill(query, .{ .glyph = " ", .style = .{ .fg = context.palette.text, .bg = context.palette.surface0 } });
    draw.background = context.palette.surface0;
    draw.line(query, .{ .text = prefix, .color = context.palette.accent });
    const prefix_width = @min(ui.measure(prefix), query.w);
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

const Drawing = struct {
    context: *widget.Context,
    input: Input,
    background: ui.Color,

    const Text = struct { text: []const u8, color: ui.Color };

    fn line(draw: *Drawing, area: ui.Rect, value: Text) void {
        _ = draw.context.buffer.writeTruncated(area, .{ .point = .{ .x = area.x, .y = area.y }, .text = value.text, .max_width = area.w, .style = .{ .fg = value.color, .bg = draw.background } });
    }

    fn rows(draw: *Drawing, area: ui.Rect) void {
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
            const row: ui.Rect = .{ .x = area.x, .y = area.y + area.h - 1 - @as(u16, @intCast(offset)), .w = area.w, .h = 1 };
            draw.background = if (index == selected) draw.context.palette.surface1 else draw.context.palette.panel_bg;
            draw.context.buffer.fill(row, .{ .glyph = " ", .style = .{ .bg = draw.background } });
            draw.line(row, .{ .text = if (index == selected) ">" else " ", .color = draw.context.palette.accent });
            var x = row.x + 2;
            var storage: [32]u8 = undefined;
            if (row.w >= 40) {
                const duration = durationText(entry.duration_ns, &storage);
                draw.line(.{ .x = x, .y = row.y, .w = 7, .h = 1 }, .{ .text = duration, .color = draw.context.palette.yellow });
                x += 8;
            }

            if (row.w >= 64) {
                const age = ageText(draw.input.now_ms -| entry.started_at_ms, &storage);
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

    fn command(draw: *Drawing, area: ui.Rect, command_text: []const u8) void {
        draw.line(area, .{ .text = command_text, .color = draw.context.palette.text });
        const query = draw.input.field.text();
        if (query.len == 0) {
            return;
        }

        var iterator: ui.GraphemeIterator = .{ .bytes = command_text };
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

    fn inspect(draw: *Drawing, area: ui.Rect, entry: Entry) void {
        const content: Inspection = .{ .entry = entry, .output = draw.input.output, .output_hint = draw.input.output_hint };
        const scroll = if (draw.input.detail_scroll == 0) 0 else @min(draw.input.detail_scroll, detailScrollLimit(area, content));
        var lines: Wrapped = .{ .draw = draw, .area = area, .skip = scroll };
        var detail = Detail.init(content);
        for (detail.texts(), 0..) |text, index| {
            lines.text(.{ .text = text, .color = if (index == 0 or index == 6) draw.context.palette.accent else if (index == 1) draw.context.palette.text else draw.context.palette.subtext0 });
        }
    }
};

pub const Inspection = struct { entry: Entry, output: []const u8, output_hint: []const u8 };

/// Bounds scroll against the same wrapped detail and responsive width used for drawing.
/// Example: `const limit = inspectionScrollLimit(application, content);`.
pub fn inspectionScrollLimit(application: ui.Rect, content: Inspection) u32 {
    const area = modalArea(application, .{ .count = 1, .inspecting = true }).inner(1);
    const width = if (area.w >= 100) area.w - area.w / 2 - 1 else area.w;
    return detailScrollLimit(.{ .w = width, .h = area.h -| 3 }, content);
}

fn detailScrollLimit(area: ui.Rect, content: Inspection) u32 {
    if (area.w == 0) {
        return 0;
    }

    var detail = Detail.init(content);
    var count: u32 = 0;
    for (detail.texts()) |text| {
        count += 1;
        var iterator: ui.GraphemeIterator = .{ .bytes = text };
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

const Detail = struct {
    content: Inspection,
    header: [80]u8 = undefined,
    header_len: usize = 0,
    author: [80]u8 = undefined,
    author_len: usize = 0,
    time: [80]u8 = undefined,
    time_len: usize = 0,
    duration: [80]u8 = undefined,
    duration_len: usize = 0,

    fn init(content: Inspection) Detail {
        var detail: Detail = .{ .content = content };
        const entry = content.entry;
        var exit_storage: [16]u8 = undefined;
        const exit = if (entry.exit_code) |code| std.fmt.bufPrint(&exit_storage, "{d}", .{code}) catch "?" else "unknown";
        const header: []const u8 = std.fmt.bufPrint(&detail.header, "#{d}  {s}  exit {s}", .{ entry.id, @tagName(entry.status), exit }) catch "";
        detail.header_len = header.len;
        const author: []const u8 = std.fmt.bufPrint(&detail.author, "{s}  pane {d}", .{ @tagName(entry.author), core.schema.id.raw(entry.pane_id) }) catch "";
        detail.author_len = author.len;
        const time = timestampText(entry.started_at_ms, &detail.time);
        detail.time_len = time.len;
        @memmove(detail.time[0..time.len], time);
        var duration_storage: [32]u8 = undefined;
        const duration: []const u8 = std.fmt.bufPrint(&detail.duration, "Duration: {s}", .{durationText(entry.duration_ns, &duration_storage)}) catch "";
        detail.duration_len = duration.len;
        return detail;
    }

    fn texts(detail: *const Detail) [8][]const u8 {
        return .{ detail.header[0..detail.header_len], detail.content.entry.command, detail.content.entry.cwd, detail.author[0..detail.author_len], detail.time[0..detail.time_len], detail.duration[0..detail.duration_len], detail.content.output_hint, detail.content.output };
    }
};

const Wrapped = struct {
    draw: *Drawing,
    area: ui.Rect,
    row: u16 = 0,
    skip: u32,

    fn text(wrapped: *Wrapped, value: Drawing.Text) void {
        if (wrapped.area.w == 0 or wrapped.row >= wrapped.area.h) {
            return;
        }

        var iterator: ui.GraphemeIterator = .{ .bytes = value.text };
        var x: u16 = 0;
        while (iterator.next()) |cluster| {
            const newline = iterator.index > 0 and value.text[iterator.index - 1] == '\n';
            if (newline or @as(u32, x) + cluster.width > wrapped.area.w) {
                if (wrapped.skip > 0) {
                    wrapped.skip -= 1;
                } else {
                    wrapped.row += 1;
                }

                x = 0;
                if (wrapped.row >= wrapped.area.h) {
                    return;
                }

                if (newline) {
                    continue;
                }
            }

            if (wrapped.skip == 0) {
                wrapped.draw.line(.{ .x = wrapped.area.x + x, .y = wrapped.area.y + wrapped.row, .w = cluster.width, .h = 1 }, .{ .text = cluster.bytes, .color = value.color });
            }

            x += cluster.width;
        }

        if (wrapped.skip > 0) {
            wrapped.skip -= 1;
        } else {
            wrapped.row += 1;
        }
    }
};

fn durationText(ns: i64, storage: []u8) []const u8 {
    const milliseconds = @divTrunc(@max(ns, 0), std.time.ns_per_ms);
    return if (milliseconds < 1000) std.fmt.bufPrint(storage, "{d}ms", .{milliseconds}) catch "?" else if (milliseconds < 60000) std.fmt.bufPrint(storage, "{d}.{d}s", .{ @divTrunc(milliseconds, 1000), @divTrunc(@mod(milliseconds, 1000), 100) }) catch "?" else if (milliseconds < 3600000) std.fmt.bufPrint(storage, "{d}m", .{@divTrunc(milliseconds, 60000)}) catch "?" else std.fmt.bufPrint(storage, "{d}h", .{@divTrunc(milliseconds, 3600000)}) catch "?";
}

fn timestampText(ms: i64, storage: []u8) []const u8 {
    if (ms < 0 or ms > 253402300799999) {
        return "Timestamp unavailable";
    }

    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@divTrunc(ms, 1000)) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const clock = epoch.getDaySeconds();
    return std.fmt.bufPrint(storage, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2} UTC", .{ day.year, @intFromEnum(month.month), month.day_index + 1, clock.getHoursIntoDay(), clock.getMinutesIntoHour(), clock.getSecondsIntoMinute() }) catch "";
}

fn ageText(ms: i64, storage: []u8) []const u8 {
    const seconds = @divTrunc(@max(ms, 0), 1000);
    return if (seconds < 60) "now" else if (seconds < 3600) std.fmt.bufPrint(storage, "{d}m ago", .{@divTrunc(seconds, 60)}) catch "?" else if (seconds < 86400) std.fmt.bufPrint(storage, "{d}h ago", .{@divTrunc(seconds, 3600)}) catch "?" else std.fmt.bufPrint(storage, "{d}d ago", .{@divTrunc(seconds, 86400)}) catch "?";
}

test "compact geometry follows content and remains inside small terminals" {
    const application: ui.Rect = .{ .w = 160, .h = 60 };
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
    const application: ui.Rect = .{ .w = 56, .h = 20 };
    const limit = inspectionScrollLimit(application, .{ .entry = entry, .output = "a\n" ** 32768, .output_hint = "Captured output" });
    try std.testing.expect(limit > 32700);
    try std.testing.expectEqual(@as(u32, 0), inspectionScrollLimit(application, .{ .entry = entry, .output = "done", .output_hint = "Captured output" }));
    var detail = Detail.init(.{ .entry = entry, .output = "", .output_hint = "" });
    try std.testing.expectEqualStrings("Timestamp unavailable", detail.texts()[4]);
}

test "history renderer puts the query below results and contains control bytes" {
    var buffer = try ui.Buffer.init(std.testing.allocator, 120, 36);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: widget.Context = .{ .buffer = &buffer, .hits = &hits, .palette = &ui.theme.default_theme.palette, .hovered = null };
    var field: picker.Field = .init("zig");
    const entry: Entry = .{ .id = 1, .pane_id = @enumFromInt(2), .command = "zig build\x1b[2J", .cwd = "/work", .started_at_ms = 1700000000000, .duration_ns = 1800000000, .exit_code = 7, .status = .completed, .author = .human };
    const input: Input = .{ .field = &field, .entries = &.{entry}, .selection = 0, .scope = "global", .now_ms = 1700000100000 };
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

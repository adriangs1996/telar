//! A command result with native selection and secondary execution metadata.
const std = @import("std");
const core = @import("telar-core");
const client = @import("telar-client");
const Canvas = @import("../Canvas.zig");
const Rect = @import("../../render/Rect.zig");
const Target = @import("../interaction/Target.zig");
const labels = @import("history_labels.zig");
const Row = @This();

bounds: Rect,
projection: *const client.Projection,
index: u16,
selected: bool,

/// Selecting a row never pastes or runs it. The delivered page revision guards
/// asynchronous replacements. Example: `try row.draw(canvas);`
pub fn draw(widget: Row, canvas: *Canvas) !void {
    if (widget.bounds.width <= 0 or widget.bounds.height <= 0) {
        return;
    }

    const history = widget.projection.history;
    const entry = &history.slice()[widget.index];
    const command = history.commandAt(widget.index) orelse entry.commandSlice();
    const palette = canvas.theme.palette;
    const px = canvas.chrome;
    const gap = px.px(10);
    const bounds: Rect = .{ .x = widget.bounds.x, .y = widget.bounds.y + px.px(2), .width = widget.bounds.width, .height = @max(0, widget.bounds.height - px.px(4)) };
    var hovered = false;
    if (canvas.widgets) |state| {
        const target = (Target{ .id = .{ .generation = widget.projection.prompt.?.generation }, .bounds = bounds, .action = .{ .history = .{ .select = .{ .index = widget.index, .revision = history.version() } } }, .layer = 1, .focusable = false, .enabled = history.phase == .ready }).labelled(command);
        const id = try state.dispatcher.add(target);
        hovered = if (state.dispatcher.hovered) |hover| hover.eql(id) else false;
    }

    if (widget.selected or hovered) {
        try canvas.fillRoundedAt(bounds, .{ .color = if (widget.selected) palette.surface1 else palette.surface0, .radius = px.px(8) });
        if (widget.selected) {
            try canvas.ringAt(bounds, .{ .color = palette.accent, .radius = px.px(8), .width = px.px(1), .alpha = 0.3 });
        }
    }

    const line_height = @max(@as(f32, @floatFromInt(canvas.metrics.cell_height)), px.rowHeight(.body));
    const small_height = px.rowHeight(.small);
    const top = bounds.y + @max(0, (bounds.height - line_height - small_height) / 2);
    const symbol: Rect = .{ .x = bounds.x + gap, .y = top, .width = px.px(20), .height = line_height };
    const color = if (entry.status == .running) palette.accent else if (entry.status == .interrupted) palette.yellow else if (entry.exit_code) |code| (if (code == 0) palette.green else palette.red) else palette.subtext0;
    _ = try canvas.textAt(symbol, .{ .text = if (entry.status == .running) "◌" else if (entry.status == .interrupted) "■" else if (entry.exit_code) |code| (if (code == 0) "✓" else "!") else "·", .face = .sans, .size = .title, .color = color });
    const title: Rect = .{ .x = symbol.x + symbol.width + gap, .y = top, .width = @max(0, bounds.width - symbol.width - gap * 3), .height = line_height };
    try widget.commandText(canvas, .{ .bounds = title, .text = command });

    var duration: [32]u8 = undefined;
    var age: [32]u8 = undefined;
    var storage: [96]u8 = undefined;
    const meta = std.fmt.bufPrint(&storage, "{s}  ·  {s}", .{ labels.duration(entry.duration_ns, &duration), labels.age(history.now_ms -| entry.started_at_ms, &age) }) catch "";
    const label: @import("../Label.zig") = .{ .text = meta, .face = .sans, .size = .small, .color = palette.subtext0 };
    const meta_width = @min(title.width, try canvas.measure(label));
    const metadata: Rect = .{ .x = title.x + title.width - meta_width, .y = top + line_height, .width = meta_width, .height = small_height };
    _ = try canvas.textAt(metadata, label);
    var path_storage: [labels.path_bytes]u8 = undefined;
    _ = try canvas.textAt(.{ .x = title.x, .y = metadata.y, .width = @max(0, title.width - meta_width - gap), .height = small_height }, .{ .text = labels.compactPath(entry.cwdSlice(), &path_storage), .face = .sans, .size = .small, .color = palette.subtext0, .alpha = 0.8 });
}

fn commandText(widget: Row, canvas: *Canvas, value: struct { bounds: Rect, text: []const u8 }) !void {
    _ = try canvas.textAt(value.bounds, .{ .text = value.text, .color = canvas.theme.palette.text });
    const query = widget.projection.prompt.?.field.text();
    var iterator: core.GraphemeIterator = .{ .bytes = value.text };
    var column: u16 = 0;
    var matched: usize = 0;
    const cell: f32 = @floatFromInt(canvas.metrics.cell_width);
    while (@as(f32, @floatFromInt(column)) * cell < value.bounds.width and matched < query.len) {
        const cluster = iterator.next() orelse break;
        const width = @as(f32, @floatFromInt(cluster.width)) * cell;
        const x = @as(f32, @floatFromInt(column)) * cell;
        if (x + width > value.bounds.width) {
            break;
        }

        if (cluster.bytes.len <= query.len - matched and std.ascii.eqlIgnoreCase(cluster.bytes, query[matched..][0..cluster.bytes.len])) {
            _ = try canvas.textAt(.{ .x = value.bounds.x + x, .y = value.bounds.y, .width = width, .height = value.bounds.height }, .{ .text = cluster.bytes, .color = canvas.theme.palette.accent, .bold = true });
            matched += cluster.bytes.len;
        }

        column += cluster.width;
    }
}

//! Shared measured-word placement for the transcript's layout and painting.
const std = @import("std");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Label = @import("Label.zig");
const Rect = @import("../render/Rect.zig");
const Flow = @This();

canvas: *Canvas,
bounds: Rect,
viewport: Rect,
row: f32,
paint: bool,
x: f32 = 0,
y: f32 = 0,
max_x: f32 = 0,
measured_bytes: usize = 0,
max_measured_span: usize = 0,
laid_out_bytes: usize = 0,
owner: ?@import("MessageLayoutOwner.zig") = null,
link: ?@import("interaction/MessageLinkControl.zig") = null,
source_start: usize = 0,
alignment: ?*@import("MessageTextAlignment.zig") = null,
table_cell: bool = false,
recording: ?*@import("MessageLayoutPlan.zig") = null,
recording_start: usize = 0,
recording_y: f32 = 0,

pub const chunk_bytes = 256;

/// Appends inline styles and links with the same source identity as plain text.
/// Example: `try flow.appendStyled(cell, .{ .text = "", .bold = header });`
pub fn appendStyled(flow: *Flow, text: []const u8, base: Label) !void {
    var spans: @import("MessageSpans.zig") = .{ .text = text, .table_cell = flow.table_cell };
    while (spans.next()) |span| {
        flow.link = null;
        if (span.destination) |destination| {
            if (flow.owner) |owner| {
                flow.link = .{ .owner = owner, .destination_offset = owner.source_offset + @as(u32, @intCast(@intFromPtr(destination.ptr) - flow.source_start)), .destination_len = @intCast(destination.len), .fragment_offset = 0 };
            }
        }

        var label = base;
        label.text = span.text;
        label.face = if (span.kind == .code) .mono else .sans;
        label.bold = base.bold or span.kind == .strong;
        label.italic = span.kind == .emphasis;
        label.underline = span.destination != null;
        label.color = if (span.destination != null) flow.canvas.theme.palette.accent else base.color;
        try flow.append(label);
    }
}

/// Appends complete shaped words, wrapping oversized words on graphemes.
/// Example: `try flow.append(.{ .text = span, .face = .sans });`
pub fn append(flow: *Flow, label: Label) !void {
    if (label.face == .sans) {
        try flow.canvas.atlas.prepareEditor();
    }

    const Cache = @import("MessageLayoutCache.zig");
    const state = flow.canvas.widgets;
    if (label.text.len < Cache.minimum_bytes or state == null or flow.owner == null or flow.alignment != null) {
        try flow.appendUncached(label);
        return;
    }

    const cache = try state.?.messageLayout(flow.canvas.atlas.allocator);
    const key = flow.cacheKey(label);
    const start_y = flow.y;
    if (!flow.paint) {
        if (cache.measurement(key)) |result| {
            flow.y += result.height;
            flow.x = result.x;
            flow.max_x = @max(flow.max_x, result.max_x);
            flow.laid_out_bytes += label.text.len;
            return;
        }
    } else {
        var paint_key = key;
        paint_key.viewport_top = flow.viewport.y - flow.bounds.y - flow.y;
        paint_key.viewport_bottom = paint_key.viewport_top + flow.viewport.height;
        if (cache.plan(paint_key)) |plan| {
            try flow.replay(label, plan);
            return;
        }

        flow.recording = cache.begin(paint_key);
        flow.recording_start = @intFromPtr(label.text.ptr);
        flow.recording_y = flow.y;
    }
    defer flow.recording = null;

    try flow.appendUncached(label);
    const result: @import("MessageLayoutResult.zig") = .{ .height = flow.y - start_y, .x = flow.x, .max_x = flow.max_x };
    cache.remember(key, result);
    if (flow.recording) |plan| {
        plan.complete(result);
    }
}

fn appendUncached(flow: *Flow, label: Label) !void {
    var index: usize = 0;
    while (index < label.text.len) {
        const start = index;
        while (index < label.text.len and label.text[index] != ' ' and label.text[index] != '\t') {
            index += 1;
        }

        while (index < label.text.len and (label.text[index] == ' ' or label.text[index] == '\t')) {
            index += 1;
        }

        var chunk_start = start;
        while (chunk_start < index) {
            const length = chunkLength(label.text[chunk_start..index]);
            var token = label;
            token.text = label.text[chunk_start..][0..length];
            try flow.appendChunk(token);
            chunk_start += length;
        }
    }
}

fn appendChunk(flow: *Flow, value: Label) !void {
    const width = try flow.measure(value);
    if (flow.x > 0 and width > flow.bounds.width - flow.x) {
        flow.newline();
    }

    if (width <= flow.bounds.width - flow.x or value.text.len > chunk_bytes) {
        try flow.paintFragment(.{ .label = value, .advance = width });
        return;
    }

    var advances: [chunk_bytes + 1]u32 = undefined;
    try flow.positions(value, advances[0 .. value.text.len + 1]);
    var offset: usize = 0;
    while (offset < value.text.len) {
        const room = @max(1, flow.bounds.width - flow.x);
        var iterator: core.GraphemeIterator = .{ .bytes = value.text, .index = offset };
        var end = offset;
        while (iterator.next() != null) {
            const from = advances[offset];
            const to = advances[iterator.index];
            const advance: f32 = @floatFromInt(@max(from, to) - @min(from, to));
            if (advance > room and end > offset) {
                break;
            }

            end = iterator.index;
            if (advance > room) {
                break;
            }
        }

        var fragment = value;
        fragment.text = value.text[offset..end];
        var advance = try flow.measure(fragment);
        if (advance > room) {
            const length = try flow.fittingPrefix(fragment, room);
            fragment.text = fragment.text[0..length];
            advance = try flow.measure(fragment);
        }

        try flow.paintFragment(.{ .label = fragment, .advance = advance });
        offset += fragment.text.len;
        if (offset < value.text.len) {
            flow.newline();
        }
    }
}

fn paintFragment(flow: *Flow, fragment: @import("MessageFragment.zig")) !void {
    flow.laid_out_bytes += fragment.label.text.len;
    if (flow.paint and flow.visible()) {
        if (flow.recording) |plan| {
            plan.append(.{ .offset = @intCast(@intFromPtr(fragment.label.text.ptr) - flow.recording_start), .len = @intCast(fragment.label.text.len), .x = flow.x, .y = flow.y - flow.recording_y, .advance = fragment.advance });
        }

        const room = @max(1, flow.bounds.width - flow.x);
        const shift = if (flow.alignment) |alignment| alignment.offset(@intFromFloat(@round(flow.y / flow.row)), flow.bounds.width) else 0;
        const area: Rect = .{ .x = flow.bounds.x + flow.x + shift, .y = flow.bounds.y + flow.y, .width = @min(room, fragment.advance + 1), .height = flow.row };
        if (fragment.label.face == .mono) {
            const first = flow.canvas.quads.items().len;
            try flow.canvas.fillRoundedAt(.{ .x = area.x, .y = area.y + flow.row * 0.12, .width = area.width, .height = flow.row * 0.76 }, .{ .color = flow.canvas.theme.palette.surface1, .radius = flow.canvas.chrome.px(3) });
            flow.canvas.quads.fadeFrom(first, 0.55);
        }

        if (flow.owner) |owner| {
            if (flow.canvas.widgets) |state| {
                if (state.thread_text) |store| {
                    const geometry = store.maps.preparing();
                    const offset = owner.source_offset + @as(u32, @intCast(@intFromPtr(fragment.label.text.ptr) - flow.source_start));
                    if (try geometry.append(flow.canvas, .{ .owner = owner, .offset = offset, .text = fragment.label.text, .bounds = area, .viewport = flow.viewport, .advance = fragment.advance, .face = fragment.label.face, .bold = fragment.label.bold, .pixel_height = flow.canvas.chrome.text(fragment.label.size) orelse flow.canvas.metrics.pixel_height })) |hit| {
                        try (@import("ThreadTextPaint.zig"){ .geometry = geometry, .fragment = hit }).draw(flow.canvas);
                    }
                }
            }
        }

        if (flow.link) |link| {
            var control = link;
            control.fragment_offset = control.owner.source_offset + @as(u32, @intCast(@intFromPtr(fragment.label.text.ptr) - flow.source_start));
            try (@import("MessageLinkButton.zig"){ .bounds = area, .viewport = flow.viewport, .control = control, .label = fragment.label, .advance = fragment.advance }).draw(flow.canvas);
        } else {
            _ = try flow.canvas.textAt(area, fragment.label);
        }
    }

    flow.x += fragment.advance;
    flow.max_x = @max(flow.max_x, flow.x);
    if (!flow.paint) {
        if (flow.alignment) |alignment| {
            alignment.observe(@intFromFloat(@round(flow.y / flow.row)), flow.x);
        }
    }
}

fn replay(flow: *Flow, label: Label, plan: *const @import("MessageLayoutPlan.zig")) !void {
    const base_y = flow.y;
    const before = flow.laid_out_bytes;
    for (plan.fragments[0..plan.len]) |fragment| {
        flow.x = fragment.x;
        flow.y = base_y + fragment.y;
        var current = label;
        current.text = label.text[fragment.offset..][0..fragment.len];
        try flow.paintFragment(.{ .label = current, .advance = fragment.advance });
    }

    flow.y = base_y + plan.result.height;
    flow.x = plan.result.x;
    flow.max_x = @max(flow.max_x, plan.result.max_x);
    flow.laid_out_bytes = before + label.text.len;
}

fn cacheKey(flow: *const Flow, label: Label) @import("MessageLayoutKey.zig") {
    var owner = flow.owner.?;
    owner.source_offset += @intCast(@intFromPtr(label.text.ptr) - flow.source_start);
    return .{ .text_hash = std.hash.Wyhash.hash(0, label.text), .text_len = label.text.len, .owner = owner, .font_identity = flow.canvas.atlas.fonts.identity, .font_revision = flow.canvas.atlas.fonts.revision, .width = flow.bounds.width, .start_x = flow.x, .row = flow.row, .scale = flow.canvas.chrome.ratio, .pixel_height = flow.canvas.chrome.text(label.size) orelse flow.canvas.metrics.pixel_height, .cell_width = flow.canvas.metrics.cell_width, .cell_height = flow.canvas.metrics.cell_height, .face = label.face, .bold = label.bold, .italic = label.italic };
}

fn positions(flow: *Flow, label: Label, output: []u32) !void {
    flow.measured_bytes += label.text.len;
    if (label.face == .sans) {
        return flow.canvas.atlas.caretPositions(.{ .text = label.text, .x = 0, .y = 0, .color = .white, .pixel_height = flow.canvas.chrome.text(label.size) orelse flow.canvas.metrics.pixel_height, .face = if (label.bold) .sans_semibold else .sans }, output);
    }

    var iterator: core.GraphemeIterator = .{ .bytes = label.text };
    var advance: u32 = 0;
    output[0] = 0;
    while (iterator.next()) |cluster| {
        @memset(output[iterator.index - cluster.bytes.len .. iterator.index], advance);
        advance += @as(u32, cluster.width) * flow.canvas.metrics.cell_width;
        output[iterator.index] = advance;
    }
}

/// Finishes the current line, including empty literal lines.
/// Example: `const height = flow.height();`
pub fn height(flow: Flow) f32 {
    return flow.y + flow.row;
}

fn newline(flow: *Flow) void {
    flow.x = 0;
    flow.y += flow.row;
}

fn visible(flow: Flow) bool {
    const y = flow.bounds.y + flow.y;
    return y + flow.row > flow.viewport.y and y < flow.viewport.y + flow.viewport.height;
}

fn fittingPrefix(flow: *Flow, label: Label, room: f32) !usize {
    var iterator: core.GraphemeIterator = .{ .bytes = label.text };
    const first = iterator.next().?;
    var low = first.bytes.len;
    var high = label.text.len;
    var fitting = low;
    while (low <= high) {
        const middle = low + (high - low) / 2;
        iterator.index = 0;
        var boundary: usize = 0;
        while (iterator.next() != null) {
            if (iterator.index > middle) {
                break;
            }

            boundary = iterator.index;
        }

        boundary = @max(first.bytes.len, boundary);
        var probe = label;
        probe.text = label.text[0..boundary];
        if (try flow.measure(probe) <= room) {
            fitting = boundary;
            low = @max(middle + 1, boundary + 1);
        } else {
            if (boundary <= first.bytes.len) {
                break;
            }

            high = boundary - 1;
        }
    }

    return fitting;
}

fn measure(flow: *Flow, label: Label) !f32 {
    flow.measured_bytes += label.text.len;
    flow.max_measured_span = @max(flow.max_measured_span, label.text.len);
    return flow.canvas.measure(label);
}

fn chunkLength(text: []const u8) usize {
    if (text.len <= chunk_bytes) {
        return text.len;
    }

    var iterator: core.GraphemeIterator = .{ .bytes = text };
    var end: usize = 0;
    while (iterator.next() != null) {
        if (iterator.index > chunk_bytes and end > 0) {
            break;
        }

        end = iterator.index;
        if (end >= chunk_bytes) {
            break;
        }
    }

    return end;
}

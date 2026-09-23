//! Shared measured-word placement for the transcript's layout and painting.
const std = @import("std");
const core = @import("telar-core");
const Canvas = @import("Canvas.zig");
const Label = @import("Label.zig");
const Rect = @import("../render/Rect.zig");
const MessageLayoutOwner = @import("MessageLayoutOwner.zig");
const MessageLinkControl = @import("interaction/MessageLinkControl.zig");
const MessageTextAlignment = @import("MessageTextAlignment.zig");
const MessageLayoutPlan = @import("MessageLayoutPlan.zig");
const MessageSpans = @import("MessageSpans.zig");
const MessageLayoutResult = @import("MessageLayoutResult.zig");
const MessageFragment = @import("MessageFragment.zig");
const ThreadTextPaint = @import("ThreadTextPaint.zig");
const MessageLinkButton = @import("MessageLinkButton.zig");
const MessageLayoutKey = @import("MessageLayoutKey.zig");
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
owner: ?MessageLayoutOwner = null,
link: ?MessageLinkControl = null,
source_start: usize = 0,
alignment: ?*MessageTextAlignment = null,
table_cell: bool = false,
recording: ?*MessageLayoutPlan = null,
recording_start: usize = 0,
recording_y: f32 = 0,

pub const chunk_bytes = 256;

/// Appends inline styles and links with the same source identity as plain text.
/// Example: `try flow.appendStyled(cell, .{ .text = "", .bold = header });`
pub fn appendStyled(self: *Flow, text: []const u8, base: Label) !void {
    var spans: MessageSpans = .{ .text = text, .table_cell = self.table_cell };
    while (spans.next()) |span| {
        self.link = null;
        if (span.destination) |destination| {
            if (self.owner) |owner| {
                self.link = .{ .owner = owner, .destination_offset = owner.source_offset + @as(u32, @intCast(@intFromPtr(destination.ptr) - self.source_start)), .destination_len = @intCast(destination.len), .fragment_offset = 0 };
            }
        }

        var label = base;
        label.text = span.text;
        label.face = if (span.kind == .code) .mono else .sans;
        label.bold = base.bold or span.kind == .strong;
        label.italic = span.kind == .emphasis;
        label.underline = span.destination != null;
        label.color = if (span.destination != null) self.canvas.theme.palette.accent else base.color;
        try self.append(label);
    }
}

/// Appends complete shaped words, wrapping oversized words on graphemes.
/// Example: `try flow.append(.{ .text = span, .face = .sans });`
pub fn append(self: *Flow, label: Label) !void {
    if (label.face == .sans) {
        try self.canvas.atlas.prepareEditor();
    }

    const Cache = @import("MessageLayoutCache.zig");
    const state = self.canvas.widgets;
    if (label.text.len < Cache.minimum_bytes or state == null or self.owner == null or self.alignment != null) {
        try self.appendUncached(label);
        return;
    }

    const cache = try state.?.messageLayout(self.canvas.atlas.allocator);
    const key = self.cacheKey(label);
    const start_y = self.y;
    if (!self.paint) {
        if (cache.measurement(key)) |result| {
            self.y += result.height;
            self.x = result.x;
            self.max_x = @max(self.max_x, result.max_x);
            self.laid_out_bytes += label.text.len;
            return;
        }
    } else {
        var paint_key = key;
        paint_key.viewport_top = self.viewport.y - self.bounds.y - self.y;
        paint_key.viewport_bottom = paint_key.viewport_top + self.viewport.height;
        if (cache.plan(paint_key)) |plan| {
            try self.replay(label, plan);
            return;
        }

        self.recording = cache.begin(paint_key);
        self.recording_start = @intFromPtr(label.text.ptr);
        self.recording_y = self.y;
    }
    defer self.recording = null;

    try self.appendUncached(label);
    const result: MessageLayoutResult = .{ .height = self.y - start_y, .x = self.x, .max_x = self.max_x };
    cache.remember(key, result);
    if (self.recording) |plan| {
        plan.complete(result);
    }
}

fn appendUncached(self: *Flow, label: Label) !void {
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
            try self.appendChunk(token);
            chunk_start += length;
        }
    }
}

fn appendChunk(self: *Flow, value: Label) !void {
    const width = try self.measure(value);
    if (self.x > 0 and width > self.bounds.width - self.x) {
        self.newline();
    }

    if (width <= self.bounds.width - self.x or value.text.len > chunk_bytes) {
        try self.paintFragment(.{ .label = value, .advance = width });
        return;
    }

    var advances: [chunk_bytes + 1]u32 = undefined;
    try self.positions(value, advances[0 .. value.text.len + 1]);
    var offset: usize = 0;
    while (offset < value.text.len) {
        const room = @max(1, self.bounds.width - self.x);
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
        var advance = try self.measure(fragment);
        if (advance > room) {
            const length = try self.fittingPrefix(fragment, room);
            fragment.text = fragment.text[0..length];
            advance = try self.measure(fragment);
        }

        try self.paintFragment(.{ .label = fragment, .advance = advance });
        offset += fragment.text.len;
        if (offset < value.text.len) {
            self.newline();
        }
    }
}

fn paintFragment(self: *Flow, fragment: MessageFragment) !void {
    self.laid_out_bytes += fragment.label.text.len;
    if (self.paint and self.visible()) {
        if (self.recording) |plan| {
            plan.append(.{ .offset = @intCast(@intFromPtr(fragment.label.text.ptr) - self.recording_start), .len = @intCast(fragment.label.text.len), .x = self.x, .y = self.y - self.recording_y, .advance = fragment.advance });
        }

        const room = @max(1, self.bounds.width - self.x);
        const shift = if (self.alignment) |alignment| alignment.offset(@intFromFloat(@round(self.y / self.row)), self.bounds.width) else 0;
        const area: Rect = .{ .x = self.bounds.x + self.x + shift, .y = self.bounds.y + self.y, .width = @min(room, fragment.advance + 1), .height = self.row };
        if (fragment.label.face == .mono) {
            const first = self.canvas.quads.items().len;
            try self.canvas.fillRoundedAt(.{ .x = area.x, .y = area.y + self.row * 0.12, .width = area.width, .height = self.row * 0.76 }, .{ .color = self.canvas.theme.palette.surface1, .radius = self.canvas.chrome.px(3) });
            self.canvas.quads.fadeFrom(first, 0.55);
        }

        if (self.owner) |owner| {
            if (self.canvas.widgets) |state| {
                if (state.thread_text) |store| {
                    const geometry = store.maps.preparing();
                    const offset = owner.source_offset + @as(u32, @intCast(@intFromPtr(fragment.label.text.ptr) - self.source_start));
                    if (try geometry.append(self.canvas, .{ .owner = owner, .offset = offset, .text = fragment.label.text, .bounds = area, .viewport = self.viewport, .advance = fragment.advance, .face = fragment.label.face, .bold = fragment.label.bold, .pixel_height = self.canvas.chrome.text(fragment.label.size) orelse self.canvas.metrics.pixel_height })) |hit| {
                        try (ThreadTextPaint{ .geometry = geometry, .fragment = hit }).draw(self.canvas);
                    }
                }
            }
        }

        if (self.link) |link| {
            var control = link;
            control.fragment_offset = control.owner.source_offset + @as(u32, @intCast(@intFromPtr(fragment.label.text.ptr) - self.source_start));
            try (MessageLinkButton{ .bounds = area, .viewport = self.viewport, .control = control, .label = fragment.label, .advance = fragment.advance }).draw(self.canvas);
        } else {
            _ = try self.canvas.textAt(area, fragment.label);
        }
    }

    self.x += fragment.advance;
    self.max_x = @max(self.max_x, self.x);
    if (!self.paint) {
        if (self.alignment) |alignment| {
            alignment.observe(@intFromFloat(@round(self.y / self.row)), self.x);
        }
    }
}

fn replay(self: *Flow, label: Label, plan: *const MessageLayoutPlan) !void {
    const base_y = self.y;
    const before = self.laid_out_bytes;
    for (plan.fragments[0..plan.len]) |fragment| {
        self.x = fragment.x;
        self.y = base_y + fragment.y;
        var current = label;
        current.text = label.text[fragment.offset..][0..fragment.len];
        try self.paintFragment(.{ .label = current, .advance = fragment.advance });
    }

    self.y = base_y + plan.result.height;
    self.x = plan.result.x;
    self.max_x = @max(self.max_x, plan.result.max_x);
    self.laid_out_bytes = before + label.text.len;
}

fn cacheKey(self: *const Flow, label: Label) MessageLayoutKey {
    var owner = self.owner.?;
    owner.source_offset += @intCast(@intFromPtr(label.text.ptr) - self.source_start);
    return .{ .text_hash = std.hash.Wyhash.hash(0, label.text), .text_len = label.text.len, .owner = owner, .font_identity = self.canvas.atlas.fonts.identity, .font_revision = self.canvas.atlas.fonts.revision, .width = self.bounds.width, .start_x = self.x, .row = self.row, .scale = self.canvas.chrome.ratio, .pixel_height = self.canvas.chrome.text(label.size) orelse self.canvas.metrics.pixel_height, .cell_width = self.canvas.metrics.cell_width, .cell_height = self.canvas.metrics.cell_height, .face = label.face, .bold = label.bold, .italic = label.italic };
}

fn positions(self: *Flow, label: Label, output: []u32) !void {
    self.measured_bytes += label.text.len;
    if (label.face == .sans) {
        return self.canvas.atlas.caretPositions(.{ .text = label.text, .x = 0, .y = 0, .color = .white, .pixel_height = self.canvas.chrome.text(label.size) orelse self.canvas.metrics.pixel_height, .face = if (label.bold) .sans_semibold else .sans }, output);
    }

    var iterator: core.GraphemeIterator = .{ .bytes = label.text };
    var advance: u32 = 0;
    output[0] = 0;
    while (iterator.next()) |cluster| {
        @memset(output[iterator.index - cluster.bytes.len .. iterator.index], advance);
        advance += @as(u32, cluster.width) * self.canvas.metrics.cell_width;
        output[iterator.index] = advance;
    }
}

/// Finishes the current line, including empty literal lines.
/// Example: `const height = flow.height();`
pub fn height(self: Flow) f32 {
    return self.y + self.row;
}

fn newline(self: *Flow) void {
    self.x = 0;
    self.y += self.row;
}

fn visible(self: Flow) bool {
    const y = self.bounds.y + self.y;
    return y + self.row > self.viewport.y and y < self.viewport.y + self.viewport.height;
}

fn fittingPrefix(self: *Flow, label: Label, room: f32) !usize {
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
        if (try self.measure(probe) <= room) {
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

fn measure(self: *Flow, label: Label) !f32 {
    self.measured_bytes += label.text.len;
    self.max_measured_span = @max(self.max_measured_span, label.text.len);
    return self.canvas.measure(label);
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

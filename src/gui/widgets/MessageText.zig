//! Markdown conversation text with one layout path for measurement and paint.
const data = @import("model");
const MessageTable = @import("MessageTable.zig");
const Theme = @import("../diagrams/Theme.zig");
const TextFit = @import("TextFit.zig");
const GlyphAtlas = @import("../text/GlyphAtlas.zig");
const assets = @import("assets");
const QuadList = @import("../render/QuadList.zig");
const std = @import("std");
const Canvas = @import("Canvas.zig");
const Rect = @import("../render/Rect.zig");
const Label = @import("Label.zig");
const MessageLayoutOwner = @import("MessageLayoutOwner.zig");
const MessageBlocks = @import("MessageBlocks.zig");
const MessageTablePaint = @import("MessageTablePaint.zig");
const MessageTextFlow = @import("MessageTextFlow.zig");
const MessageCodePaint = @import("MessageCodePaint.zig");
const DiffPaint = @import("DiffPaint.zig");
const WrappedLines = @import("overlays/WrappedLines.zig");
const ThreadTextPaint = @import("ThreadTextPaint.zig");
const Text = @This();

bounds: Rect,
viewport: Rect,
text: []const u8,
markdown: bool = true,
muted: bool = false,
code: bool = false,
diff: bool = false,
owner: ?MessageLayoutOwner = null,

/// Returns the height used by the exact same word layout as the painter.
/// Example: `const height = try message.measure(canvas);`
pub fn measure(self: Text, canvas: *Canvas) !f32 {
    return self.layout(canvas, false);
}

/// Paints only visible lines and keeps code and inline styles inside the column.
/// Example: `try message.draw(canvas);`
pub fn draw(self: Text, canvas: *Canvas) !void {
    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, self.viewport);
    _ = try self.layout(canvas, true);
}

fn layout(self: Text, canvas: *Canvas, paint: bool) !f32 {
    if (self.code) {
        return self.codeBlock(canvas, .{ .block = .{ .text = self.text, .kind = .code, .language = if (self.diff) "Changes" else "Output" }, .paint = paint });
    }

    var blocks: MessageBlocks = .{ .text = self.text, .markdown = self.markdown };
    var y: f32 = 0;
    while (blocks.next()) |block| {
        if (block.kind == .spacer or block.kind == .rule) {
            if (paint and block.kind == .rule and self.visible(self.bounds.y + y, canvas.chrome.px(18))) {
                try canvas.fillAt(.{ .x = self.bounds.x, .y = self.bounds.y + y + canvas.chrome.px(8), .width = self.bounds.width, .height = 1 }, canvas.theme.palette.surface1);
            }

            y += canvas.chrome.px(if (block.kind == .rule) @as(f32, 18) else 8);
            continue;
        }

        if (block.kind == .code) {
            var code = self;
            code.bounds.y += y;
            y += try code.codeBlock(canvas, .{ .block = block, .paint = paint });
            continue;
        }

        if (block.kind == .table) {
            y += try (MessageTablePaint{ .bounds = .{ .x = self.bounds.x, .y = self.bounds.y + y, .width = self.bounds.width, .height = 0 }, .viewport = self.viewport, .table = MessageTable.parse(block.text).?, .owner = self.owner, .source_start = @intFromPtr(self.text.ptr), .muted = self.muted }).layout(canvas, paint);
            continue;
        }

        const indent = if (block.kind == .bullet or block.kind == .quote) @min(canvas.chrome.px(26), self.bounds.width / 5) else 0;
        const top = if (block.kind == .heading) canvas.chrome.px(7) else 0;
        const row = canvas.chrome.px(if (block.kind == .heading) @as(f32, 30) else 25);
        var flow: MessageTextFlow = .{ .canvas = canvas, .bounds = .{ .x = self.bounds.x + indent, .y = self.bounds.y + y + top, .width = @max(1, self.bounds.width - indent), .height = 0 }, .viewport = self.viewport, .row = row, .paint = paint, .owner = self.owner, .source_start = @intFromPtr(self.text.ptr) };
        const label: Label = .{ .text = block.text, .face = .sans, .size = if (block.kind == .heading) .title else .body, .bold = block.kind == .heading, .color = if (self.muted or block.kind == .quote) canvas.theme.palette.subtext0 else canvas.theme.palette.text };
        if (self.markdown) {
            try flow.appendStyled(block.text, label);
        } else {
            try flow.append(label);
        }

        if (paint and block.kind == .bullet and self.visible(self.bounds.y + y, row)) {
            _ = try canvas.textAt(.{ .x = self.bounds.x, .y = self.bounds.y + y, .width = indent, .height = row }, .{ .text = block.marker, .face = .sans, .size = .body, .color = canvas.theme.palette.subtext0 });
        }

        if (paint and block.kind == .quote and self.visible(self.bounds.y + y, flow.height())) {
            try canvas.fillRoundedAt(.{ .x = self.bounds.x + canvas.chrome.px(3), .y = self.bounds.y + y + canvas.chrome.px(3), .width = canvas.chrome.px(2), .height = @max(0, flow.height() - canvas.chrome.px(6)) }, .{ .color = canvas.theme.palette.overlay0, .radius = 1 });
        }

        y += top + flow.height() + canvas.chrome.px(if (block.kind == .heading) @as(f32, 5) else 2);
    }

    return y;
}

fn codeBlock(self: Text, canvas: *Canvas, input: MessageCodePaint) !f32 {
    if (self.diff or std.mem.eql(u8, input.block.language, "diff") or std.mem.eql(u8, input.block.language, "patch")) {
        var diff: DiffPaint = .{ .canvas = canvas, .bounds = self.bounds, .viewport = self.viewport, .text = input.block.text, .owner = self.owner, .source_start = @intFromPtr(self.text.ptr), .paint = input.paint };
        return diff.layout();
    }

    const MermaidBlock = @import("MermaidBlock.zig");
    const diagram: ?MermaidBlock = if (input.block.isMermaid() and self.owner != null) .{ .bounds = self.bounds, .request = .{ .owner = self.owner.?, .block_offset = input.block.source_offset, .text = input.block.text, .theme = Theme.init(canvas.theme), .scale = canvas.chrome.ratio } } else null;
    var diagram_view = if (diagram) |value| value.lookup(canvas) else null;
    if (diagram_view) |view| {
        if (view == .ready) {
            const value = diagram.?;
            const ready_height = value.measure(canvas, view.ready);
            if (input.paint and self.visible(self.bounds.y, ready_height)) {
                try value.draw(canvas, view.ready);
            }

            return ready_height;
        }
    }

    const inset = @min(canvas.chrome.px(14), self.bounds.width / 8);
    const header = canvas.chrome.px(30);
    const row: f32 = @max(canvas.chrome.px(21), @as(f32, @floatFromInt(canvas.metrics.cell_height)));
    const columns: u16 = @intFromFloat(@max(1, @min(65535, @floor((self.bounds.width - 2 * inset) / @as(f32, @floatFromInt(canvas.metrics.cell_width))))));
    var lines: WrappedLines = .{ .text = input.block.text, .width = columns };
    const height = header + @as(f32, @floatFromInt(lines.count())) * row + canvas.chrome.px(12);
    if (!input.paint or !self.visible(self.bounds.y, height + canvas.chrome.px(10))) {
        return height + canvas.chrome.px(10);
    }

    if (diagram) |value| {
        if (diagram_view == null or diagram_view.? == .pending) {
            diagram_view = value.enqueue(canvas);
        }
    }

    const card: Rect = .{ .x = self.bounds.x, .y = self.bounds.y + canvas.chrome.px(4), .width = self.bounds.width, .height = height };
    try canvas.fillRoundedAt(card, .{ .color = canvas.theme.palette.surface0, .radius = canvas.chrome.px(8) });
    try canvas.ringAt(card, .{ .color = canvas.theme.palette.overlay0, .width = 1, .radius = canvas.chrome.px(8), .alpha = 0.4 });
    var storage: [TextFit.max_bytes]u8 = undefined;
    var label: Label = .{ .text = if (diagram != null) MermaidBlock.label(diagram_view) else if (input.block.language.len > 0) input.block.language else "Code", .face = .sans, .size = .small, .color = canvas.theme.palette.subtext0 };
    label.text = try (TextFit{ .canvas = canvas, .width = @max(0, card.width - 2 * inset) }).fit(label, &storage);
    if (self.visible(card.y, header)) {
        _ = try canvas.textAt(.{ .x = card.x + inset, .y = card.y, .width = card.width - 2 * inset, .height = header }, label);
    }
    var y = card.y + header;
    while (lines.next()) |line| {
        if (self.visible(y, row)) {
            const area: Rect = .{ .x = card.x + inset, .y = y, .width = card.width - 2 * inset, .height = row };
            if (self.owner) |owner| {
                if (canvas.widgets) |state| {
                    if (state.thread_text) |store| {
                        const geometry = store.maps.preparing();
                        const at = owner.source_offset + @as(u32, @intCast(@intFromPtr(line.ptr) - @intFromPtr(self.text.ptr)));
                        if (try geometry.append(canvas, .{ .owner = owner, .offset = at, .text = line, .bounds = area, .viewport = self.viewport, .advance = 0, .face = .mono, .pixel_height = canvas.metrics.pixel_height })) |hit| {
                            try (ThreadTextPaint{ .geometry = geometry, .fragment = hit }).draw(canvas);
                        }
                    }
                }
            }
            _ = try canvas.textAt(area, .{ .text = line, .color = canvas.theme.palette.text });
        }

        y += row;
    }

    return height + canvas.chrome.px(10);
}

fn visible(self: Text, y: f32, height: f32) bool {
    return y + height > self.viewport.y and y < self.viewport.y + self.viewport.height;
}

test "offscreen Markdown decorations cannot exhaust the visible frame quad budget" {
    var atlas = try GlyphAtlas.init(std.testing.allocator, .{ .font = assets.jetbrains_mono, .pixel_height = 16 });
    defer atlas.deinit();
    var quads = QuadList.init(std.testing.allocator);
    defer quads.deinit();
    try quads.quads.ensureTotalCapacity(std.testing.allocator, 96);
    quads.limit = 96;
    var canvas: Canvas = .{ .atlas = &atlas, .quads = &quads, .origin = .{ 0, 0 }, .metrics = .{ .cell_width = 10, .cell_height = 24, .baseline = 18, .pixel_height = 16 }, .theme = data.theme_support.default_theme, .chrome = .{ .body = 16, .title = 18, .small = 12 } };
    var storage: [48 * 1024]u8 = undefined;
    const pattern = "---\n- bullet\n> quote\n```zig\ncode\n```\n";
    var len: usize = 0;
    while (len + pattern.len <= storage.len) : (len += pattern.len) {
        @memcpy(storage[len..][0..pattern.len], pattern);
    }

    var message: Text = .{ .bounds = .{ .x = 0, .y = 0, .width = 400, .height = 0 }, .viewport = .{ .x = 0, .y = 0, .width = 400, .height = 64 }, .text = storage[0..len] };
    const height = try message.measure(&canvas);
    message.bounds.y = 64 - height;
    try message.draw(&canvas);
    try std.testing.expect(quads.items().len > 0 and quads.items().len < 96);
    for (quads.items()) |quad| {
        try std.testing.expect(quad.y >= 0 and quad.y + quad.height <= 64.001);
    }
}

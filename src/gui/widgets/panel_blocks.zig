//! Lays out and paints the block components of a panel or a tooltip, one
//! under the other: headings, wrapped text, meter rows, key-value rows,
//! callouts, button rows, dividers and single-line rows of inline components.
const InlineRow = @import("InlineRow.zig");
const BlockStack = @import("BlockStack.zig");
const BlockLayout = @import("BlockLayout.zig");
const BlockScope = @import("BlockScope.zig");
const data = @import("model");
const gfx = @import("gfx");
const std = @import("std");
const Rect = gfx.Rect;
const client = @import("telar-client");
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const Label = @import("Label.zig");
const bar_tone = @import("bar_tone.zig");
const inline_nodes = @import("inline_nodes.zig");
const TextFit = @import("TextFit.zig");

pub const block_gap: f32 = 12;
/// Lines a heading or text block wraps to; a longer one ends its last line
/// with an ellipsis.
const max_lines = 8;
const line_height: f32 = 18;
const heading_line: f32 = 21;
const detail_line: f32 = 16;
const meter_row_height: f32 = 36;
const label_share: f32 = 0.38;
const column_gap: f32 = 14;
const value_width: f32 = 40;
const meter_height: f32 = 4;
const marker_height: f32 = 12;
const kv_height: f32 = 20;
const inline_height: f32 = 22;
const divider_margin: f32 = 5;
const callout_height: f32 = 52;
const callout_padding: f32 = 12;
const callout_radius: f32 = 8;
const icon_side: f32 = 18;
const button_height: f32 = 28;
const button_padding: f32 = 12;
const button_radius: f32 = 6;
const button_gap: f32 = 8;
const primary_alpha: f32 = 0.18;

/// The height of the stack at `width`.
/// Example: `const height = try panel_blocks.height(canvas, &panel.content, .{ .scope = .{}, .width = 388 });`
pub fn height(canvas: *Canvas, content: anytype, layout: BlockLayout) !f32 {
    var total: f32 = 0;
    var count: usize = 0;
    for (content.slice(), 0..) |node, index| {
        if (!inScope(node, layout.scope)) {
            continue;
        }

        if (count > 0) {
            total += canvas.chrome.px(block_gap);
        }
        total += try blockHeight(canvas, .{ .content = content, .index = index, .width = layout.width, .facts = layout.facts });
        count += 1;
    }

    return total;
}

/// Paints the stack from the top of `bounds`, clipped to it.
/// Example: `try panel_blocks.draw(canvas, &panel.content, .{ .context = context, .bounds = body, .scope = .{ .interactive = true }, .facts = &facts });`
pub fn draw(canvas: *Canvas, content: anytype, stack: BlockStack) !void {
    const first = canvas.quads.items().len;
    defer canvas.quads.clipFrom(first, stack.bounds);
    var y = stack.bounds.y;
    var count: usize = 0;
    for (content.slice(), 0..) |node, index| {
        if (!inScope(node, stack.scope)) {
            continue;
        }

        if (count > 0) {
            y += canvas.chrome.px(block_gap);
        }
        const block: Block(@TypeOf(content)) = .{ .content = content, .index = index, .width = stack.bounds.width, .facts = stack.facts };
        const block_height = try blockHeight(canvas, block);
        try drawBlock(canvas, block, .{
            .stack = stack,
            .bounds = .{ .x = stack.bounds.x, .y = y, .width = stack.bounds.width, .height = block_height },
        });
        y += block_height;
        count += 1;
    }
}

fn Block(comptime Content: type) type {
    return struct {
        content: Content,
        index: usize,
        width: f32,
        facts: *const data.BarFacts,
    };
}

const Placement = struct {
    stack: BlockStack,
    bounds: Rect,
};

fn inScope(node: data.Node, scope: BlockScope) bool {
    return node.parent == scope.parent and node.in_tooltip == scope.tooltip;
}

fn blockHeight(canvas: *Canvas, block: anytype) !f32 {
    const chrome = canvas.chrome;
    const view = data.NodeView.of(block.content, block.index, block.facts);
    return switch (view.node.kind) {
        .heading => @as(f32, @floatFromInt(try lineCount(canvas, headingLabel(canvas, view), block.width))) * chrome.px(heading_line),
        .text => @as(f32, @floatFromInt(try lineCount(canvas, textLabel(canvas, view), block.width))) * chrome.px(line_height),
        .meter_row => if (view.detail.len != 0) chrome.px(meter_row_height) else chrome.px(line_height),
        .kv => chrome.px(kv_height),
        .callout => chrome.px(callout_height),
        .actions, .button => chrome.px(button_height),
        .divider => chrome.px(1) + 2 * chrome.px(divider_margin),
        else => chrome.px(inline_height),
    };
}

fn drawBlock(canvas: *Canvas, block: anytype, placement: Placement) !void {
    const view = data.NodeView.of(block.content, block.index, block.facts);
    const bounds = placement.bounds;
    switch (view.node.kind) {
        .heading => try drawLines(canvas, headingLabel(canvas, view), .{ .bounds = bounds, .line = canvas.chrome.px(heading_line) }),
        .text => try drawLines(canvas, textLabel(canvas, view), .{ .bounds = bounds, .line = canvas.chrome.px(line_height) }),
        .meter_row => try drawMeterRow(canvas, view, bounds),
        .kv => try drawKeyValue(canvas, view, bounds),
        .callout => try drawCallout(canvas, block, placement),
        .actions => try drawButtons(canvas, block, placement),
        .button => _ = try drawButton(canvas, view, .{ .stack = placement.stack, .right = bounds.x + bounds.width, .y = bounds.y }),
        .divider => try canvas.fillAt(.{
            .x = bounds.x,
            .y = bounds.y + canvas.chrome.px(divider_margin),
            .width = bounds.width,
            .height = canvas.chrome.px(1),
        }, canvas.theme.palette.surface0),
        else => try drawInline(canvas, block.content, .{ .index = block.index, .bounds = bounds, .facts = block.facts }),
    }
}

fn headingLabel(canvas: *const Canvas, view: data.NodeView) Label {
    return .{
        .text = view.text,
        .color = bar_tone.ink(canvas, view.node.tone),
        .bold = true,
        .face = .sans,
        .size = .title,
    };
}

fn textLabel(canvas: *const Canvas, view: data.NodeView) Label {
    return .{
        .text = view.text,
        .color = if (view.node.tone == .neutral) canvas.theme.palette.subtext0 else bar_tone.ink(canvas, view.node.tone),
        .face = .sans,
        .size = .body,
    };
}

/// Wraps at spaces, at most `max_lines` lines; the last one takes the rest
/// of the text and `drawLines` fits it with an ellipsis.
fn wrap(canvas: *Canvas, label: Label, width: f32, lines: *[max_lines][]const u8) !usize {
    const text = label.text;
    var count: usize = 0;
    var start: usize = 0;
    while (start < text.len and count < max_lines) {
        if (count == max_lines - 1) {
            lines[count] = text[start..];
            return count + 1;
        }

        var end = start;
        var fitted = start;
        while (end < text.len) {
            const next = std.mem.indexOfScalarPos(u8, text, end + 1, ' ') orelse text.len;
            var candidate = label;
            candidate.text = text[start..next];
            if (try canvas.measure(candidate) > width and fitted > start) {
                break;
            }

            fitted = next;
            end = next;
        }

        lines[count] = text[start..fitted];
        count += 1;
        start = fitted;
        while (start < text.len and text[start] == ' ') {
            start += 1;
        }
    }

    return @max(count, 1);
}

fn lineCount(canvas: *Canvas, label: Label, width: f32) !usize {
    var lines: [max_lines][]const u8 = undefined;
    return wrap(canvas, label, width, &lines);
}

fn drawLines(canvas: *Canvas, label: Label, lines_layout: Lines) !void {
    var lines: [max_lines][]const u8 = undefined;
    const count = try wrap(canvas, label, lines_layout.bounds.width, &lines);
    var fitted: [TextFit.max_bytes]u8 = undefined;
    for (lines[0..count], 0..) |line, index| {
        var part = label;
        part.text = line;
        if (index == max_lines - 1) {
            part.text = try (TextFit{ .canvas = canvas, .width = lines_layout.bounds.width }).fit(part, &fitted);
        }

        _ = try canvas.textAt(.{
            .x = lines_layout.bounds.x,
            .y = lines_layout.bounds.y + @as(f32, @floatFromInt(index)) * lines_layout.line,
            .width = lines_layout.bounds.width,
            .height = lines_layout.line,
        }, part);
    }
}

const Lines = struct {
    bounds: Rect,
    line: f32,
};

fn drawMeterRow(canvas: *Canvas, view: data.NodeView, bounds: Rect) !void {
    const chrome = canvas.chrome;
    const palette = canvas.theme.palette;
    const label_width = @round(bounds.width * label_share);
    const top_line = chrome.px(line_height);
    _ = try canvas.textAt(.{ .x = bounds.x, .y = bounds.y, .width = label_width, .height = top_line }, .{
        .text = view.text,
        .color = palette.text,
        .face = .sans,
        .size = .body,
    });
    if (view.detail.len != 0) {
        _ = try canvas.textAt(.{ .x = bounds.x, .y = bounds.y + top_line, .width = label_width, .height = chrome.px(detail_line) }, .{
            .text = view.detail,
            .color = palette.subtext0,
            .face = .sans,
            .size = .small,
        });
    }

    const value_box = chrome.px(value_width);
    const track_x = bounds.x + label_width + chrome.px(column_gap);
    const track_width = @max(0, bounds.x + bounds.width - value_box - chrome.px(column_gap) - track_x);
    const track_height = chrome.px(meter_height);
    try inline_nodes.drawTrack(canvas, .{
        .bounds = .{
            .x = track_x,
            .y = @round(bounds.y + (bounds.height - track_height) / 2),
            .width = track_width,
            .height = track_height,
        },
        .value = view.node.value,
        .tone = view.node.tone,
        .marker = view.node.marker,
        .marker_height = chrome.px(marker_height),
    });

    var buffer: [8]u8 = undefined;
    const number: Label = .{
        .text = std.fmt.bufPrint(&buffer, "{d}%", .{view.node.percent()}) catch "",
        .color = bar_tone.ink(canvas, view.node.tone),
        .face = .sans,
        .size = .body,
    };
    const width = try canvas.measure(number);
    _ = try canvas.textAt(.{ .x = bounds.x + bounds.width - width, .y = bounds.y, .width = width, .height = bounds.height }, number);
}

fn drawKeyValue(canvas: *Canvas, view: data.NodeView, bounds: Rect) !void {
    _ = try canvas.textAt(bounds, inline_nodes.captionColored(canvas, view.text));
    const label: Label = .{
        .text = view.detail,
        .color = bar_tone.ink(canvas, view.node.tone),
        .face = .sans,
        .size = .body,
    };
    const width = @min(bounds.width, try canvas.measure(label));
    _ = try canvas.textAt(.{ .x = bounds.x + bounds.width - width, .y = bounds.y, .width = width, .height = bounds.height }, label);
}

fn drawCallout(canvas: *Canvas, block: anytype, placement: Placement) !void {
    const chrome = canvas.chrome;
    const palette = canvas.theme.palette;
    const bounds = placement.bounds;
    const view = data.NodeView.of(block.content, block.index, block.facts);
    try canvas.fillRoundedAt(bounds, .{ .radius = chrome.px(callout_radius), .color = canvas.covering(palette.panel_bg) });
    try canvas.ringAt(bounds, .{ .width = chrome.px(1), .color = palette.surface1, .radius = chrome.px(callout_radius) });
    const padding = chrome.px(callout_padding);
    var x = bounds.x + padding;
    if (view.node.icon) |icon| {
        const side = chrome.px(icon_side);
        try canvas.iconAt(.{ .x = x, .y = bounds.y, .width = side, .height = bounds.height }, .{
            .text = icon.nerdGlyph(),
            .color = bar_tone.mark(canvas, view.node.tone),
            .face = .sans,
            .size = .body,
        });
        x += side + padding;
    }

    var right = bounds.x + bounds.width - padding;
    for (block.content.slice(), 0..) |child, index| {
        if (child.parent != block.index or child.kind != .button) {
            continue;
        }

        right = try drawButton(canvas, data.NodeView.of(block.content, index, block.facts), .{
            .stack = placement.stack,
            .right = right,
            .y = bounds.y + (bounds.height - chrome.px(button_height)) / 2,
        }) - padding;
        break;
    }

    const text_width = @max(0, right - x);
    const title_height = chrome.px(line_height);
    const detail_height = if (view.detail.len != 0) chrome.px(detail_line) else 0;
    const top = bounds.y + (bounds.height - title_height - detail_height) / 2;
    _ = try canvas.textAt(.{ .x = x, .y = top, .width = text_width, .height = title_height }, .{
        .text = view.text,
        .color = palette.text,
        .face = .sans,
        .size = .body,
    });
    if (view.detail.len != 0) {
        _ = try canvas.textAt(.{ .x = x, .y = top + title_height, .width = text_width, .height = detail_height }, .{
            .text = view.detail,
            .color = palette.subtext0,
            .face = .sans,
            .size = .small,
        });
    }
}

fn drawButtons(canvas: *Canvas, block: anytype, placement: Placement) !void {
    var right = placement.bounds.x + placement.bounds.width;
    var index = block.content.node_count;
    // Right to left, so the first button declared ends up leftmost.
    while (index > 0) {
        index -= 1;
        const child = block.content.slice()[index];
        if (child.parent != block.index or child.kind != .button) {
            continue;
        }

        right = try drawButton(canvas, data.NodeView.of(block.content, index, block.facts), .{
            .stack = placement.stack,
            .right = right,
            .y = placement.bounds.y,
        }) - canvas.chrome.px(button_gap);
    }
}

/// Paints one button ending at `right` and returns its left edge.
fn drawButton(canvas: *Canvas, view: data.NodeView, button: Button) !f32 {
    const chrome = canvas.chrome;
    const palette = canvas.theme.palette;
    const label: Label = .{
        .text = view.text,
        .color = if (view.node.primary) palette.accent else palette.text,
        .bold = view.node.primary,
        .face = .sans,
        .size = .body,
    };
    const width = try canvas.measure(label) + 2 * chrome.px(button_padding);
    const bounds: Rect = .{
        .x = @round(button.right - width),
        .y = @round(button.y),
        .width = width,
        .height = chrome.px(button_height),
    };
    const intent: client.Intent = .{ .panel_component = view.index };
    const hovered = button.stack.scope.interactive and button.stack.context.isHovered(.{ .intent = intent });
    if (view.node.primary) {
        try canvas.fillRoundedAt(bounds, .{ .radius = chrome.px(button_radius), .color = palette.accent, .alpha = if (hovered) primary_alpha * 2 else primary_alpha });
    } else {
        try canvas.fillRoundedAt(bounds, .{ .radius = chrome.px(button_radius), .color = if (hovered) palette.surface1 else palette.surface0 });
    }

    _ = try canvas.textAt(.{ .x = bounds.x + chrome.px(button_padding), .y = bounds.y, .width = width - chrome.px(button_padding), .height = bounds.height }, label);
    if (button.stack.scope.interactive) {
        button.stack.context.bands.add(.{ .area = bounds, .action = .{ .intent = intent } });
    }

    return bounds.x;
}

const Button = struct {
    stack: BlockStack,
    right: f32,
    y: f32,
};

/// One inline component on its own line; a group lays its children out.
/// Example: `try panel_blocks.drawInline(canvas, content, .{ .index = 3, .bounds = row, .facts = &facts });`
pub fn drawInline(canvas: *Canvas, content: anytype, row: InlineRow) !void {
    const chrome = canvas.chrome;
    const bounds = row.bounds;
    const view = data.NodeView.of(content, row.index, row.facts);
    if (view.node.kind != .group) {
        const width = try inline_nodes.width(canvas, view, .full);
        return inline_nodes.draw(canvas, view, .{ .bounds = .{ .x = bounds.x, .y = bounds.y, .width = width, .height = bounds.height } });
    }

    var x = bounds.x;
    if (view.node.mark) |mark| {
        try inline_nodes.drawMark(canvas, mark, .{ .x = x, .y = bounds.y, .width = bounds.width, .height = bounds.height });
        x += inline_nodes.groupChrome(canvas, view) - 2 * chrome.px(inline_nodes.group_padding) + chrome.px(inline_nodes.child_gap);
    }

    for (content.slice(), 0..) |child, index| {
        if (child.parent != row.index or child.in_tooltip) {
            continue;
        }

        const child_view = data.NodeView.of(content, index, row.facts);
        const width = try inline_nodes.width(canvas, child_view, .full);
        try inline_nodes.draw(canvas, child_view, .{ .bounds = .{ .x = x, .y = bounds.y, .width = width, .height = bounds.height } });
        x += width + chrome.px(inline_nodes.child_gap);
    }
}


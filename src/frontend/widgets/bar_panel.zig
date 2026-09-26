//! The open bar panel in the terminal: a rounded box above the bottom row,
//! under the component that opened it, with the same blocks the native panel
//! shows. It is drawn as a modal layer, so clicks on it never reach a pane.

const BarPanelInput = @import("BarPanelInput.zig");
const cellgrid = @import("cellgrid");
const data = @import("model");
const std = @import("std");
const Context = @import("Context.zig");
const bar_content = @import("bar_content.zig");

const cell_pixels: u16 = 8;
const min_columns: u16 = 32;
const overflow_columns: u16 = 34;
const max_lines = 3;
const label_share: u16 = 38;
const percent: u16 = 100;
const value_cells: u16 = 5;
const track_full = "▰";
const track_empty = "▱";
const marker = "│";
const close = "×";

/// Where the open panel goes, or an empty rect when none is open.
/// Example: `const area = bar_panel.area(&context, input);`
pub fn area(context: *const Context, input: BarPanelInput) cellgrid.Rect {
    const panel = &input.bar_state.panel;
    if (!panel.isOpen() or input.bottom.y == 0) {
        return .{};
    }

    const columns = @min(input.application.w, width(input));
    const rows = @min(input.bottom.y, height(input, columns));
    const anchor_end = anchorEnd(context, panel) orelse input.bottom.x + input.bottom.w;
    const x = @min(anchor_end -| columns, input.application.x + input.application.w -| columns);
    return .{ .x = x, .y = input.bottom.y - rows, .w = columns, .h = rows };
}

/// Draws the panel into `box`, from `area`, and returns the cells it covers.
/// Example: `const drawn = bar_panel.render(&context, input, box);`
pub fn render(context: *Context, input: BarPanelInput, box: cellgrid.Rect) cellgrid.Rect {
    if (box.w < 4 or box.h < 3) {
        return .{};
    }

    const palette = context.palette;
    const panel = &input.bar_state.panel;
    const frame: cellgrid.Style = .{ .fg = palette.surface1, .bg = palette.panel_bg };
    context.buffer.fill(box, .{ .glyph = " ", .style = .{ .fg = palette.text, .bg = palette.panel_bg } });
    drawBorder(context, box, frame);
    context.hits.beginLayer(box);
    defer context.hits.endLayer();

    var title_storage: [data.PanelHeading.max_title_bytes + 2]u8 = undefined;
    const title = std.fmt.bufPrint(&title_storage, " {s} ", .{titleOf(input)}) catch "";
    _ = context.buffer.writeTruncated(box, .{ .point = .{ .x = box.x + 2, .y = box.y }, .text = title, .max_width = box.w -| 6, .style = .{ .fg = palette.text, .bg = palette.panel_bg, .flags = .{ .bold = true } } });
    const close_cell: cellgrid.Rect = .{ .x = box.x + box.w - 3, .y = box.y, .w = 1, .h = 1 };
    _ = context.buffer.writeText(box, .{ .point = .{ .x = close_cell.x, .y = box.y }, .text = close, .style = .{ .fg = if (context.isHovered(.close_panel)) palette.text else palette.subtext0, .bg = palette.panel_bg } });
    context.hits.add(close_cell, .close_panel);

    const inner: cellgrid.Rect = .{ .x = box.x + 2, .y = box.y + 1, .w = box.w -| 4, .h = box.h -| 2 };
    var y = inner.y;
    if (statusText(panel)) |status| {
        _ = context.buffer.writeTruncated(inner, .{ .point = .{ .x = inner.x, .y = y }, .text = status, .max_width = inner.w, .style = .{ .fg = if (panel.status == .failed) palette.red else palette.subtext0, .bg = palette.panel_bg } });
        y += 2;
    }

    switch (panel.target) {
        .none => {},
        .configured => drawBlocks(context, .{ .content = &panel.content, .area = inner, .y = y, .facts = input.facts }),
        .overflow => drawOverflow(context, input, .{ .x = inner.x, .y = y, .w = inner.w, .h = inner.y + inner.h -| y }),
    }

    return box;
}

fn titleOf(input: BarPanelInput) []const u8 {
    return switch (input.bar_state.panel.target) {
        .configured => |index| if (input.bar_state.layout.panel(index)) |heading| heading.title() else "",
        .overflow => "More",
        .none => "",
    };
}

fn width(input: BarPanelInput) u16 {
    return switch (input.bar_state.panel.target) {
        .configured => |index| if (input.bar_state.layout.panel(index)) |heading| @max(min_columns, heading.width / cell_pixels) else min_columns,
        .overflow => overflow_columns,
        .none => 0,
    };
}

fn height(input: BarPanelInput, columns: u16) u16 {
    const panel = &input.bar_state.panel;
    const inner = columns -| 4;
    var rows: u16 = 2;
    if (statusText(panel) != null) {
        rows += 2;
    }

    rows += switch (panel.target) {
        .configured => blocksHeight(&panel.content, inner),
        .overflow => hiddenCount(input),
        .none => 0,
    };
    return rows;
}

fn anchorEnd(context: *const Context, panel: *const data.Panel) ?u16 {
    for (context.hits.registered()) |entry| {
        const matches = switch (panel.target) {
            .configured => if (panel.anchor) |anchor| entry.action == .bar_component and std.meta.eql(entry.action.bar_component, anchor) else false,
            .overflow => entry.action == .toggle_bar_overflow,
            .none => false,
        };
        if (matches) {
            return entry.rect.x + entry.rect.w;
        }
    }

    return null;
}

fn statusText(panel: *const data.Panel) ?[]const u8 {
    return switch (panel.status) {
        .loading => if (panel.content.isEmpty() and panel.target != .overflow) "Loading…" else null,
        .ready => null,
        .failed => if (panel.content.isEmpty()) "Could not update." else "Could not update; showing the last result.",
    };
}

fn blocksHeight(content: *const data.PanelContent, inner: u16) u16 {
    var rows: u16 = 0;
    var count: u16 = 0;
    for (content.slice()) |node| {
        if (!node.isRoot()) {
            continue;
        }

        if (count > 0) {
            rows += 1;
        }
        rows += blockRows(content, node, inner);
        count += 1;
    }

    return rows;
}

fn blockRows(content: *const data.PanelContent, node: data.Node, inner: u16) u16 {
    return switch (node.kind) {
        .heading, .text => @intCast(wrap(content.text(node.text), inner, null)),
        .meter_row, .callout => if (node.detail.len != 0) 2 else 1,
        else => 1,
    };
}

fn drawBlocks(context: *Context, blocks: Blocks) void {
    var y = blocks.y;
    var count: u16 = 0;
    const content = blocks.content;
    for (content.slice(), 0..) |node, index| {
        if (!node.isRoot()) {
            continue;
        }

        if (count > 0) {
            y += 1;
        }
        const rows = blockRows(content, node, blocks.area.w);
        if (y + rows > blocks.area.y + blocks.area.h) {
            return;
        }

        const row: cellgrid.Rect = .{ .x = blocks.area.x, .y = y, .w = blocks.area.w, .h = rows };
        drawBlock(context, .{ .content = content, .index = index, .area = row, .facts = blocks.facts });
        y += rows;
        count += 1;
    }
}

const Blocks = struct {
    content: *const data.PanelContent,
    area: cellgrid.Rect,
    y: u16,
    facts: *const data.BarFacts,
};

fn drawBlock(context: *Context, block: Block) void {
    const palette = context.palette;
    const view = data.NodeView.of(block.content, block.index, block.facts);
    const row = block.area;
    const plain: cellgrid.Style = .{ .fg = palette.text, .bg = palette.panel_bg };
    const quiet: cellgrid.Style = .{ .fg = palette.subtext0, .bg = palette.panel_bg };
    switch (view.node.kind) {
        .heading => drawWrapped(context, view.text, .{ .area = row, .style = .{ .fg = palette.text, .bg = palette.panel_bg, .flags = .{ .bold = true } } }),
        .text => drawWrapped(context, view.text, .{ .area = row, .style = quiet }),
        .meter_row => drawMeterRow(context, view, row),
        .kv => {
            write(context, row, .{ .x = row.x, .text = view.text, .style = quiet });
            write(context, row, .{ .x = row.x + row.w -| cellgrid.text.measure(view.detail), .text = view.detail, .style = plain });
        },
        .callout => {
            var right = row.x + row.w;
            for (block.content.slice(), 0..) |child, index| {
                if (child.parent == block.index and child.kind == .button) {
                    right = drawButton(context, data.NodeView.of(block.content, index, block.facts), .{ .area = row, .right = right });
                    break;
                }
            }

            write(context, .{ .x = row.x, .y = row.y, .w = right -| row.x, .h = 1 }, .{ .x = row.x, .text = view.text, .style = plain });
            if (view.detail.len != 0) {
                write(context, .{ .x = row.x, .y = row.y + 1, .w = row.w, .h = 1 }, .{ .x = row.x, .text = view.detail, .style = quiet });
            }
        },
        .actions => {
            var right = row.x + row.w;
            var index = block.content.node_count;
            while (index > 0) {
                index -= 1;
                const child = block.content.slice()[index];
                if (child.parent == block.index and child.kind == .button) {
                    right = drawButton(context, data.NodeView.of(block.content, index, block.facts), .{ .area = row, .right = right }) -| 1;
                }
            }
        },
        .button => _ = drawButton(context, view, .{ .area = row, .right = row.x + row.w }),
        .divider => {
            var x = row.x;
            while (x < row.x + row.w) : (x += 1) {
                write(context, row, .{ .x = x, .text = "─", .style = .{ .fg = palette.surface1, .bg = palette.panel_bg } });
            }
        },
        else => _ = bar_content.drawComponent(context, block.content, .{ .index = block.index, .area = row, .facts = block.facts }),
    }
}

const Block = struct {
    content: *const data.PanelContent,
    index: usize,
    area: cellgrid.Rect,
    facts: *const data.BarFacts,
};

fn drawMeterRow(context: *Context, view: data.NodeView, row: cellgrid.Rect) void {
    const palette = context.palette;
    const label_width = row.w * label_share / percent;
    write(context, row, .{ .x = row.x, .text = view.text, .style = .{ .fg = palette.text, .bg = palette.panel_bg } });
    if (view.detail.len != 0) {
        write(context, row, .{ .x = row.x, .y = row.y + 1, .text = view.detail, .style = .{ .fg = palette.subtext0, .bg = palette.panel_bg } });
    }

    const track_x = row.x + label_width + 1;
    const cells = row.w -| label_width -| value_cells -| 2;
    const filled = (@as(u32, view.node.value) * cells + data.Node.full_scale / 2) / data.Node.full_scale;
    const marked: ?u32 = if (view.node.marker) |value| @min(cells -| 1, (@as(u32, value) * cells) / data.Node.full_scale) else null;
    const style: cellgrid.Style = .{ .fg = roleColor(context, view.node.tone.markRole()), .bg = palette.panel_bg };
    for (0..cells) |cell| {
        const glyph = if (marked != null and cell == marked.?) marker else if (cell < filled) track_full else track_empty;
        write(context, row, .{ .x = track_x + @as(u16, @intCast(cell)), .text = glyph, .style = style });
    }

    var buffer: [8]u8 = undefined;
    const value = std.fmt.bufPrint(&buffer, "{d}%", .{view.node.percent()}) catch "";
    write(context, row, .{ .x = row.x + row.w -| cellgrid.text.measure(value), .text = value, .style = .{ .fg = roleColor(context, view.node.tone.inkRole()), .bg = palette.panel_bg } });
}

/// Draws `[ text ]` ending at `right` and returns its left edge.
fn drawButton(context: *Context, view: data.NodeView, button: Button) u16 {
    const palette = context.palette;
    const label_width = cellgrid.text.measure(view.text) + 4;
    const x = button.right -| label_width;
    const cell: cellgrid.Rect = .{ .x = x, .y = button.area.y, .w = label_width, .h = 1 };
    const hovered = context.isHovered(.{ .panel_component = view.index });
    const style: cellgrid.Style = .{
        .fg = if (view.node.primary) palette.panel_bg else palette.text,
        .bg = if (view.node.primary) palette.accent else if (hovered) palette.surface1 else palette.surface0,
        .flags = .{ .bold = view.node.primary },
    };
    context.buffer.fill(cell, .{ .glyph = " ", .style = style });
    write(context, cell, .{ .x = x + 2, .text = view.text, .style = style });
    context.hits.add(cell, .{ .panel_component = view.index });
    return x;
}

const Button = struct {
    area: cellgrid.Rect,
    right: u16,
};

fn hiddenCount(input: BarPanelInput) u16 {
    const overflow = input.overflow orelse return 0;
    return @intCast(overflow.count);
}

/// One row per component the bar had no room for; a click acts as it would
/// in the bar.
fn drawOverflow(context: *Context, input: BarPanelInput, rows: cellgrid.Rect) void {
    const overflow = input.overflow orelse return;
    var y = rows.y;
    for (overflow.slice()) |component| {
        if (y >= rows.y + rows.h) {
            return;
        }

        const content = input.bar_state.layout.content(component.position) orelse continue;
        const row: cellgrid.Rect = .{ .x = rows.x, .y = y, .w = rows.w, .h = 1 };
        const node = content.slice()[component.node];
        if (node.isActionable() or content.hasTooltip(component.node)) {
            context.hits.add(row, .{ .bar_component = component });
        }

        _ = bar_content.drawComponent(context, content, .{ .index = component.node, .area = row, .facts = input.facts });
        y += 1;
    }
}

fn drawWrapped(context: *Context, text: []const u8, wrapped: Wrapped) void {
    var lines: [max_lines][]const u8 = undefined;
    const count = wrap(text, wrapped.area.w, &lines);
    for (lines[0..count], 0..) |line, index| {
        write(context, wrapped.area, .{ .x = wrapped.area.x, .y = wrapped.area.y + @as(u16, @intCast(index)), .text = line, .style = wrapped.style });
    }
}

const Wrapped = struct {
    area: cellgrid.Rect,
    style: cellgrid.Style,
};

/// Wraps at spaces into at most `max_lines` lines of `columns` cells.
fn wrap(text: []const u8, columns: u16, lines: ?*[max_lines][]const u8) usize {
    var count: usize = 0;
    var start: usize = 0;
    while (start < text.len and count < max_lines) {
        var end = text.len;
        if (cellgrid.text.measure(text[start..]) > columns and count < max_lines - 1) {
            var fitted = start;
            var cursor = start;
            while (std.mem.indexOfScalarPos(u8, text, cursor + 1, ' ')) |space| {
                if (cellgrid.text.measure(text[start..space]) > columns) {
                    break;
                }

                fitted = space;
                cursor = space;
            }
            end = if (fitted > start) fitted else text.len;
        }

        if (lines) |value| {
            value[count] = text[start..end];
        }
        count += 1;
        start = end;
        while (start < text.len and text[start] == ' ') {
            start += 1;
        }
    }

    return @max(count, 1);
}

fn drawBorder(context: *Context, box: cellgrid.Rect, style: cellgrid.Style) void {
    const right = box.x + box.w - 1;
    const bottom = box.y + box.h - 1;
    var x = box.x + 1;
    while (x < right) : (x += 1) {
        write(context, box, .{ .x = x, .y = box.y, .text = "─", .style = style });
        write(context, box, .{ .x = x, .y = bottom, .text = "─", .style = style });
    }

    var y = box.y + 1;
    while (y < bottom) : (y += 1) {
        write(context, box, .{ .x = box.x, .y = y, .text = "│", .style = style });
        write(context, box, .{ .x = right, .y = y, .text = "│", .style = style });
    }

    write(context, box, .{ .x = box.x, .y = box.y, .text = "╭", .style = style });
    write(context, box, .{ .x = right, .y = box.y, .text = "╮", .style = style });
    write(context, box, .{ .x = box.x, .y = bottom, .text = "╰", .style = style });
    write(context, box, .{ .x = right, .y = bottom, .text = "╯", .style = style });
}

fn write(context: *Context, clip: cellgrid.Rect, text: Text) void {
    const y = text.y orelse clip.y;
    const limit = clip.x + clip.w;
    if (text.x >= limit or text.text.len == 0) {
        return;
    }

    _ = context.buffer.writeTruncated(clip, .{ .point = .{ .x = text.x, .y = y }, .text = text.text, .max_width = limit - text.x, .style = text.style });
}

const Text = struct {
    x: u16,
    y: ?u16 = null,
    text: []const u8,
    style: cellgrid.Style,
};

fn roleColor(context: *const Context, role: data.bar_values.PaletteColor) cellgrid.Color {
    return switch (role) {
        inline else => |value| @field(context.palette, @tagName(value)),
    };
}

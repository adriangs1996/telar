//! The configured components of the bottom bar in one pixel row. The row is
//! fitted by priority, laid out left, centre and right, with hairlines around
//! groups and a hover target for every component with an action, a url or a
//! tooltip. Components that did not fit are counted in a `+N` chip.
const data = @import("model");
const client = @import("telar-client");
const gfx = @import("gfx");
const std = @import("std");
const Rect = gfx.Rect;
const Canvas = @import("Canvas.zig");
const Context = @import("Context.zig");
const inline_nodes = @import("inline_nodes.zig");
const BarRow = @This();

/// The slots the row shows, in fitting order; legacy `top.right` content
/// follows the right slot.
pub const positions = [_]data.bar_values.Position{ .bottom_left, .bottom_center, .bottom_right, .top_right };

const unit_gap: f32 = 16;
const slot_gap: f32 = 24;
const separator_height: f32 = 12;
const hover_radius: f32 = 4;
const chip_padding: f32 = 5;
const chip_height: f32 = 16;
const chip_gap: f32 = 8;
const max_overflow_label = 4;

context: *const Context,
/// The row between the band's padding and the reserved TLS badge.
area: Rect,

/// Example: `try (BarRow{ .context = context, .area = row }).draw(canvas);`
pub fn draw(self: BarRow, canvas: *Canvas) !void {
    if (self.area.width <= 0) {
        return;
    }

    var cpu_buffer: [data.CpuHistory.capacity]u8 = undefined;
    var machine_buffer: [client.Machines.capacity]data.MachineFact = undefined;
    const facts = barFacts(self.context, &cpu_buffer, &machine_buffer);
    var input: data.FitInput = .{ .available = self.area.width };
    try measure(canvas, .{ .layout = &self.context.projection.bar_state.layout, .facts = &facts, .input = &input });
    const fitted = data.bar_fitting.fit(&input);
    self.recordOverflow(&input, &fitted);
    var widths: [positions.len]f32 = undefined;
    for (&widths, 0..) |*width, slot| {
        width.* = slotWidth(&input, &fitted, slot);
    }

    const chrome = canvas.chrome;
    const right = self.area.x + self.area.width;
    var right_end = right;
    if (fitted.hidden > 0) {
        right_end -= input.overflow_width;
        try self.overflowChip(canvas, .{
            .count = fitted.hidden,
            .x = right_end + chrome.px(chip_gap),
        });
    }

    var starts: [positions.len]f32 = undefined;
    starts[3] = right_end - widths[3];
    starts[2] = if (widths[3] > 0) starts[3] - chrome.px(slot_gap) - widths[2] else right_end - widths[2];
    starts[0] = self.area.x;
    const left_end = self.area.x + widths[0] + (if (widths[0] > 0) chrome.px(slot_gap) else 0);
    const right_start = @min(starts[2], starts[3]) - chrome.px(slot_gap);
    const centred = self.area.x + (self.area.width - widths[1]) / 2;
    starts[1] = std.math.clamp(centred, left_end, @max(left_end, right_start - widths[1]));

    for (positions, 0..) |position, slot| {
        const content = input.slots[slot] orelse continue;
        try self.drawSlot(canvas, .{
            .position = position,
            .slot = slot,
            .content = content,
            .x = @round(starts[slot]),
            .input = &input,
            .fitted = &fitted,
            .facts = &facts,
        });
    }
}

/// Records the top-level components the fit hid, for the overflow panel.
fn recordOverflow(self: BarRow, input: *const data.FitInput, fitted: *const data.BarFit) void {
    const overflow = self.context.bar_overflow orelse return;
    for (positions, 0..) |position, slot| {
        const content = input.slots[slot] orelse continue;
        for (content.slice(), 0..) |node, index| {
            if (node.isRoot() and !fitted.isVisible(slot, index)) {
                overflow.append(.{
                    .position = position,
                    .node = @intCast(index),
                });
            }
        }
    }
}

/// The host facts built-in components read, from the projection.
/// Example: `const facts = BarRow.barFacts(context, &buffer, &machines);`
pub fn barFacts(context: *const Context, cpu_buffer: *[data.CpuHistory.capacity]u8, machine_buffer: *[client.Machines.capacity]data.MachineFact) data.BarFacts {
    const projection = context.projection;
    return .{
        .metrics = projection.system_metrics,
        .cpu = projection.model.cpu_history.ordered(cpu_buffer),
        .now = projection.bar_state.now,
        .machines = machineFacts(projection.machines, machine_buffer),
    };
}

fn machineFacts(table: ?*const client.Machines, buffer: *[client.Machines.capacity]data.MachineFact) []const data.MachineFact {
    const machines = table orelse return &.{};
    if (machines.count() <= 1) {
        return &.{};
    }

    var len: usize = 0;
    for (0..client.Machines.capacity) |index| {
        const slot: u8 = @intCast(index);
        if (!machines.shown(slot)) {
            continue;
        }

        buffer[len] = .{
            .label = machines.label(slot),
            .active = slot == machines.active,
            .phase = machines.phase[slot],
            .attention = machines.attention[slot],
            .cpu_percent = machines.cpu_percent[slot],
        };
        len += 1;
    }

    return buffer[0..len];
}

/// Measures every component of the configured slots for the fitter.
fn measure(canvas: *Canvas, request: Measurement) !void {
    const chrome = canvas.chrome;
    const input = request.input;
    input.unit_gap = chrome.px(unit_gap);
    input.child_gap = chrome.px(inline_nodes.child_gap);
    input.slot_gap = chrome.px(slot_gap);
    input.overflow_width = try chipWidth(canvas, "+99") + chrome.px(chip_gap);
    for (positions, 0..) |position, slot| {
        const content = request.layout.content(position) orelse continue;
        input.slots[slot] = content;
        for (content.slice(), 0..) |node, index| {
            if (node.in_tooltip) {
                continue;
            }

            const view = data.NodeView.of(content, index, request.facts);
            input.full[slot][index] = if (node.kind == .group)
                inline_nodes.groupChrome(canvas, view)
            else
                try inline_nodes.width(canvas, view, .full);
            input.compact[slot][index] = if (node.kind == .meter) try inline_nodes.width(canvas, view, .compact) else 0;
        }
    }
}

const Measurement = struct {
    layout: *const data.BarLayout,
    facts: *const data.BarFacts,
    input: *data.FitInput,
};

fn slotWidth(input: *const data.FitInput, fitted: *const data.BarFit, slot: usize) f32 {
    const content = input.slots[slot] orelse return 0;
    var total: f32 = 0;
    var units: usize = 0;
    for (content.slice(), 0..) |node, index| {
        if (!node.isRoot() or !fitted.isVisible(slot, index)) {
            continue;
        }

        const width = data.bar_fitting.rootWidth(input, fitted, slot, index);
        if (width <= 0) {
            continue;
        }

        total += width + if (units > 0) input.unit_gap else 0;
        units += 1;
    }

    return total;
}

fn drawSlot(self: BarRow, canvas: *Canvas, slot: SlotDraw) !void {
    const chrome = canvas.chrome;
    const content = slot.content;
    var x = slot.x;
    var previous_group: ?bool = null;
    for (content.slice(), 0..) |node, index| {
        if (!node.isRoot() or !slot.fitted.isVisible(slot.slot, index)) {
            continue;
        }

        const width = data.bar_fitting.rootWidth(slot.input, slot.fitted, slot.slot, index);
        if (width <= 0) {
            continue;
        }

        const is_group = node.kind == .group;
        if (previous_group) |was_group| {
            if (was_group or is_group) {
                try separator(canvas, .{
                    .x = @round(x + slot.input.unit_gap / 2),
                    .y = self.area.y,
                    .width = chrome.px(1),
                    .height = self.area.height,
                });
            }

            x += slot.input.unit_gap;
        }

        const bounds: Rect = .{
            .x = x,
            .y = self.area.y,
            .width = width,
            .height = self.area.height,
        };
        try self.drawRoot(canvas, .{
            .slot = slot,
            .index = index,
            .bounds = bounds,
        });
        previous_group = is_group;
        x += width;
    }
}

const SlotDraw = struct {
    position: data.bar_values.Position,
    slot: usize,
    content: *const data.Content,
    x: f32,
    input: *const data.FitInput,
    fitted: *const data.BarFit,
    facts: *const data.BarFacts,
};

fn drawRoot(self: BarRow, canvas: *Canvas, root: Root) !void {
    const slot = root.slot;
    const content = slot.content;
    const node = content.slice()[root.index];
    const component: data.BarComponent = .{
        .position = slot.position,
        .node = @intCast(root.index),
    };
    const target = targetBounds(canvas, root.bounds);
    const interactive = node.isActionable() or content.hasTooltip(@intCast(root.index));
    if (interactive) {
        if (self.context.isHovered(.{ .intent = .{ .bar_component = component } })) {
            try canvas.fillRoundedAt(target, .{ .radius = canvas.chrome.px(hover_radius), .color = canvas.theme.palette.surface0 });
        }

        self.context.bands.add(.{
            .area = target,
            .action = .{ .intent = .{ .bar_component = component } },
        });
    }

    const view = data.NodeView.of(content, root.index, slot.facts);
    if (node.kind != .group) {
        return inline_nodes.draw(canvas, view, .{ .bounds = root.bounds, .level = slot.fitted.level(slot.slot, root.index) });
    }

    try drawGroup(canvas, .{
        .root = root,
        .view = view,
    });
}

const Root = struct {
    slot: SlotDraw,
    index: usize,
    bounds: Rect,
};

fn drawGroup(canvas: *Canvas, group: Group) !void {
    const chrome = canvas.chrome;
    const slot = group.root.slot;
    const content = slot.content;
    const node = group.view.node;
    var x = group.root.bounds.x + chrome.px(inline_nodes.group_padding);
    var leading = false;
    if (node.mark) |mark| {
        try inline_nodes.drawMark(canvas, mark, rowAt(group.root.bounds, x));
        x += inline_nodes.groupChrome(canvas, group.view) - 2 * chrome.px(inline_nodes.group_padding);
        leading = true;
    } else if (node.icon) |icon| {
        var label = inline_nodes.caption(icon.nerdGlyph());
        label.color = canvas.theme.palette.subtext0;
        try canvas.iconAt(rowAt(group.root.bounds, x), label);
        x += inline_nodes.groupChrome(canvas, group.view) - 2 * chrome.px(inline_nodes.group_padding);
        leading = true;
    }

    for (content.slice(), 0..) |child, index| {
        if (child.parent != group.root.index or child.in_tooltip or !slot.fitted.isVisible(slot.slot, index)) {
            continue;
        }

        const level = slot.fitted.level(slot.slot, index);
        const width = switch (level) {
            .full => slot.input.full[slot.slot][index],
            .compact => slot.input.compact[slot.slot][index],
            .hidden => 0,
        };
        if (width <= 0) {
            continue;
        }

        if (leading) {
            x += slot.input.child_gap;
        }

        var bounds = rowAt(group.root.bounds, x);
        bounds.width = width;
        try inline_nodes.draw(canvas, data.NodeView.of(content, index, slot.facts), .{ .bounds = bounds, .level = level });
        x += width;
        leading = true;
    }
}

const Group = struct {
    root: Root,
    view: data.NodeView,
};

fn overflowChip(self: BarRow, canvas: *Canvas, chip: OverflowChip) !void {
    const chrome = canvas.chrome;
    const palette = canvas.theme.palette;
    var storage: [max_overflow_label]u8 = undefined;
    const text = std.fmt.bufPrint(&storage, "+{d}", .{chip.count}) catch "+";
    const width = try chipWidth(canvas, text);
    const height = chrome.px(chip_height);
    const bounds: Rect = .{
        .x = @round(chip.x),
        .y = @round(self.area.y + (self.area.height - height) / 2),
        .width = width,
        .height = height,
    };
    const hovered = self.context.isHovered(.{ .intent = .toggle_bar_overflow }) or
        self.context.projection.bar_state.panel.target == .overflow;
    try canvas.fillRoundedAt(bounds, .{ .radius = chrome.px(hover_radius), .color = if (hovered) palette.surface1 else palette.surface0 });
    var label = inline_nodes.caption(text);
    label.color = if (hovered) palette.text else palette.subtext0;
    _ = try canvas.textAt(.{
        .x = bounds.x + chrome.px(chip_padding),
        .y = bounds.y,
        .width = width - chrome.px(chip_padding),
        .height = bounds.height,
    }, label);
    self.context.bands.add(.{
        .area = bounds,
        .action = .{ .intent = .toggle_bar_overflow },
    });
}

const OverflowChip = struct {
    count: u8,
    x: f32,
};

fn chipWidth(canvas: *Canvas, text: []const u8) !f32 {
    return try canvas.measure(inline_nodes.caption(text)) + 2 * canvas.chrome.px(chip_padding);
}

fn separator(canvas: *Canvas, column: Rect) !void {
    const height = canvas.chrome.px(separator_height);
    try canvas.fillAt(.{
        .x = column.x,
        .y = @round(column.y + (column.height - height) / 2),
        .width = column.width,
        .height = height,
    }, canvas.theme.palette.surface1);
}

fn targetBounds(canvas: *const Canvas, bounds: Rect) Rect {
    const height = @min(bounds.height, canvas.chrome.px(inline_nodes.row_height));
    return .{
        .x = bounds.x,
        .y = @round(bounds.y + (bounds.height - height) / 2),
        .width = bounds.width,
        .height = height,
    };
}

fn rowAt(bounds: Rect, x: f32) Rect {
    return .{
        .x = x,
        .y = bounds.y,
        .width = @max(0, bounds.x + bounds.width - x),
        .height = bounds.height,
    };
}

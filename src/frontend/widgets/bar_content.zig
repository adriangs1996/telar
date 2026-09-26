//! Allocation-free cell rendering of configured bar components. The slot is
//! fitted by the same priority rule as the native bar; meters become `▰▱`
//! tracks, sparklines become block elements and groups are set apart by a
//! thin rule.

const LeafCursor = @import("LeafCursor.zig");
const ComponentPlacement = @import("ComponentPlacement.zig");
const BarContentInput = @import("BarContentInput.zig");
const cellgrid = @import("cellgrid");
const data = @import("model");
const std = @import("std");
const Context = @import("Context.zig");

const unit_gap: u16 = 3;
const track_cells = 4;
const sparkline_cells = 8;
const sparkline_levels = [_][]const u8{ "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" };
const track_full = "▰";
const track_empty = "▱";
const rule = "│";
const full_percent: u32 = 100;
/// The `+N` chip and the space before it.
const overflow_cells: f32 = 4;

pub fn render(context: *Context, area: cellgrid.Rect, input: BarContentInput) void {
    if (area.isEmpty()) {
        return;
    }

    var fit_input: data.FitInput = .{
        .available = @floatFromInt(area.w),
        .unit_gap = unit_gap,
        .child_gap = 1,
        .overflow_width = overflowWidth(),
    };
    measure(&fit_input, input);
    const fitted = data.bar_fitting.fit(&fit_input);
    recordOverflow(context, input, &fitted);
    const width: u16 = @intFromFloat(@min(fitted.width, @as(f32, @floatFromInt(area.w))));
    var x = switch (input.alignment) {
        .left => area.x,
        .center => area.x + (area.w - width) / 2,
        .right => area.x + area.w - width,
    };

    var previous_group: ?bool = null;
    for (input.content.slice(), 0..) |node, index| {
        if (!node.isRoot() or !fitted.isVisible(0, index)) {
            continue;
        }

        const root_width: u16 = @intFromFloat(@max(0, data.bar_fitting.rootWidth(&fit_input, &fitted, 0, index)));
        if (root_width == 0) {
            continue;
        }

        if (previous_group) |was_group| {
            const glyph = if (was_group or node.kind == .group) rule else " ";
            _ = context.buffer.writeText(area, .{ .point = .{ .x = x + 1, .y = area.y }, .text = glyph, .style = quiet(context) });
            x += unit_gap;
        }

        const root_area: cellgrid.Rect = .{ .x = x, .y = area.y, .w = @min(root_width, area.x + area.w -| x), .h = 1 };
        drawRoot(context, .{ .input = input, .fit_input = &fit_input, .fitted = &fitted, .index = index, .area = root_area });
        previous_group = node.kind == .group;
        x += root_width;
    }

    if (fitted.hidden > 0) {
        var storage: [4]u8 = undefined;
        const label = std.fmt.bufPrint(&storage, "+{d}", .{fitted.hidden}) catch "+";
        const chip: cellgrid.Rect = .{ .x = x + 1, .y = area.y, .w = @intCast(label.len), .h = 1 };
        _ = context.buffer.writeText(area, .{ .point = .{ .x = chip.x, .y = area.y }, .text = label, .style = quiet(context) });
        context.hits.add(chip, .toggle_bar_overflow);
    }
}

fn recordOverflow(context: *Context, input: BarContentInput, fitted: *const data.BarFit) void {
    const overflow = context.bar_overflow orelse return;
    for (input.content.slice(), 0..) |node, index| {
        if (node.isRoot() and !fitted.isVisible(0, index)) {
            overflow.append(.{
                .position = input.position,
                .node = @intCast(index),
            });
        }
    }
}

/// Draws one top-level component on its own, at full width, for lists
/// such as the overflow panel. Returns the cells it used.
/// Example: `_ = bar_content.drawComponent(context, content, .{ .index = 2, .area = row, .facts = facts });`
pub fn drawComponent(context: *Context, content: anytype, component: ComponentPlacement) u16 {
    const view = data.NodeView.of(content, component.index, component.facts);
    const area = component.area;
    var x = area.x;
    if (view.node.kind != .group) {
        return drawLeaf(context, view, .{ .area = area, .x = x });
    }

    if (view.node.mark) |mark| {
        x += context.drawIcon(.{ .area = area, .point = .{ .x = x, .y = area.y }, .icon = mark.icon(), .style = plain(context) }) + 1;
    } else if (view.node.icon) |icon| {
        x += context.drawIcon(.{ .area = area, .point = .{ .x = x, .y = area.y }, .icon = icon, .style = quiet(context) }) + 1;
    }

    for (content.slice(), 0..) |child, index| {
        if (child.parent == component.index and !child.in_tooltip) {
            x += drawLeaf(context, data.NodeView.of(content, index, component.facts), .{ .area = area, .x = x }) + 1;
        }
    }

    return x - area.x;
}

/// The host facts built-in components read.
/// Example: `const facts = bar_content.barFacts(model, bar_state, &buffer);`
pub fn barFacts(model: *const data.ClientModel, bar_state: *const data.BarsState, cpu_buffer: *[data.CpuHistory.capacity]u8) data.BarFacts {
    return .{
        .metrics = model.system_metrics,
        .cpu = model.cpu_history.ordered(cpu_buffer),
        .now = bar_state.now,
    };
}

/// The cells the slot needs with every component at full width.
/// Example: `const desired = bar_content.desiredWidth(.{ .content = content, .facts = &facts, .position = .bottom_left });`
pub fn desiredWidth(input: BarContentInput) u16 {
    var fit_input: data.FitInput = .{
        .available = std.math.floatMax(f32),
        .unit_gap = unit_gap,
        .child_gap = 1,
    };
    measure(&fit_input, input);
    const fitted = data.bar_fitting.fit(&fit_input);
    return @intFromFloat(@min(fitted.width, std.math.maxInt(u16)));
}

fn measure(fit_input: *data.FitInput, input: BarContentInput) void {
    fit_input.slots[0] = input.content;
    for (input.content.slice(), 0..) |node, index| {
        if (node.in_tooltip) {
            continue;
        }

        const view = data.NodeView.of(input.content, index, input.facts);
        fit_input.full[0][index] = if (node.kind == .group) groupChrome(view) else @floatFromInt(leafWidth(view, .full));
        fit_input.compact[0][index] = if (node.kind == .meter) @floatFromInt(leafWidth(view, .compact)) else 0;
    }
}

fn overflowWidth() f32 {
    return overflow_cells;
}


fn groupChrome(view: data.NodeView) f32 {
    const leading = if (view.node.mark) |mark| mark.icon() else view.node.icon orelse return -1;
    return @floatFromInt(iconCells(leading));
}

/// The cells an icon's fallback glyph takes; wide emoji take two.
fn iconCells(icon: data.icons.Icon) u16 {
    return @max(1, cellgrid.text.measure(icon.unicodeGlyph()));
}

/// The cells one leaf takes at `level`.
pub fn leafWidth(view: data.NodeView, level: data.FitLevel) u16 {
    if (level == .hidden) {
        return 0;
    }

    const node = view.node;
    var buffer: [data.bar_clock.max_output_bytes]u8 = undefined;
    return switch (node.kind) {
        .label, .heading, .text => cellgrid.text.measure(view.text),
        .icon => if (node.icon) |icon| iconCells(icon) else cellgrid.text.measure(view.text),
        .mark => iconCells((node.mark orelse data.Mark.telar).icon()),
        .meter => meterWidth(view, level),
        .sparkline => @intCast(@min(view.samples.len, sparkline_cells)),
        .badge => cellgrid.text.measure(view.text) + 2,
        .clock => cellgrid.text.measure(data.bar_clock.format(&buffer, view.text, view.facts.now)),
        .metric => metricWidth(view),
        .kv => cellgrid.text.measure(view.text) + 1 + cellgrid.text.measure(view.detail),
        .group, .meter_row, .callout, .actions, .button, .divider => 0,
    };
}

fn meterWidth(view: data.NodeView, level: data.FitLevel) u16 {
    var buffer: [8]u8 = undefined;
    var total = cellgrid.text.measure(meterText(&buffer, view));
    if (view.text.len != 0) {
        total += cellgrid.text.measure(view.text) + 1;
    }
    if (level == .full) {
        total += track_cells + 1;
    }

    return total;
}

fn metricWidth(view: data.NodeView) u16 {
    const name = view.node.metric;
    const metrics = view.facts.metrics;
    if (!data.bar_metrics.available(name, metrics)) {
        return 0;
    }

    var buffer: [data.bar_metrics.max_value_bytes]u8 = undefined;
    const value = cellgrid.text.measure(data.bar_metrics.value(&buffer, name, metrics));
    return switch (name) {
        .battery => iconCells(batteryIcon(data.bar_metrics.percent(name, metrics))) + 1 + value,
        .memory => cellgrid.text.measure(data.bar_metrics.label(name)) + 1 + value,
        .cpu => cellgrid.text.measure(data.bar_metrics.label(name)) + 1 + sparklineWidth(view.facts.cpu) + value,
    };
}

fn sparklineWidth(samples: []const u8) u16 {
    const count: u16 = @intCast(@min(samples.len, sparkline_cells));
    return if (count == 0) 0 else count + 1;
}

fn meterText(buffer: *[8]u8, view: data.NodeView) []const u8 {
    if (view.detail.len != 0) {
        return view.detail;
    }

    return std.fmt.bufPrint(buffer, "{d}%", .{view.node.percent()}) catch "";
}

fn drawRoot(context: *Context, root: Root) void {
    const content = root.input.content;
    const node = content.slice()[root.index];
    if (node.isActionable() or content.hasTooltip(@intCast(root.index))) {
        context.hits.add(root.area, .{ .bar_component = .{ .position = root.input.position, .node = @intCast(root.index) } });
    }

    const view = data.NodeView.of(content, root.index, root.input.facts);
    if (node.kind != .group) {
        _ = drawLeaf(context, view, .{ .area = root.area, .x = root.area.x, .level = root.fitted.level(0, root.index) });
        return;
    }

    var x = root.area.x;
    var leading = false;
    if (node.mark) |mark| {
        x += context.drawIcon(.{ .area = root.area, .point = .{ .x = x, .y = root.area.y }, .icon = mark.icon(), .style = plain(context) });
        leading = true;
    } else if (node.icon) |icon| {
        x += context.drawIcon(.{ .area = root.area, .point = .{ .x = x, .y = root.area.y }, .icon = icon, .style = quiet(context) });
        leading = true;
    }

    for (content.slice(), 0..) |child, index| {
        if (child.parent != root.index or child.in_tooltip or !root.fitted.isVisible(0, index)) {
            continue;
        }

        if (leading) {
            x += 1;
        }
        x += drawLeaf(context, data.NodeView.of(content, index, root.input.facts), .{ .area = root.area, .x = x, .level = root.fitted.level(0, index) });
        leading = true;
    }
}

const Root = struct {
    input: BarContentInput,
    fit_input: *const data.FitInput,
    fitted: *const data.BarFit,
    index: usize,
    area: cellgrid.Rect,
};

/// Draws one leaf at `at.x` and returns the cells it used.
pub fn drawLeaf(context: *Context, view: data.NodeView, at: LeafCursor) u16 {
    if (at.level == .hidden) {
        return 0;
    }

    const node = view.node;
    var writer: Writer = .{ .context = context, .area = at.area, .x = at.x };
    switch (node.kind) {
        .label, .heading, .text => writer.text(view.text, labelStyle(context, node)),
        .icon => if (node.icon) |icon| writer.icon(icon, tone(context, node.tone, .mark)) else writer.text(view.text, tone(context, node.tone, .mark)),
        .mark => writer.icon((node.mark orelse data.Mark.telar).icon(), plain(context)),
        .meter => {
            if (view.text.len != 0) {
                writer.text(view.text, quiet(context));
                writer.space();
            }
            if (at.level == .full) {
                writer.track(node.value, tone(context, node.tone, .mark));
                writer.space();
            }

            var buffer: [8]u8 = undefined;
            writer.text(meterText(&buffer, view), tone(context, node.tone, .ink));
        },
        .sparkline => writer.sparkline(view.samples, tone(context, node.tone, .mark)),
        .badge => {
            var style = tone(context, node.tone, .mark);
            style.bg = style.fg;
            style.fg = context.palette.panel_bg;
            writer.text(" ", style);
            writer.text(view.text, style);
            writer.text(" ", style);
        },
        .clock => {
            var buffer: [data.bar_clock.max_output_bytes]u8 = undefined;
            writer.text(data.bar_clock.format(&buffer, view.text, view.facts.now), tone(context, node.tone, .ink));
        },
        .metric => drawMetric(&writer, view),
        .kv => {
            writer.text(view.text, quiet(context));
            writer.space();
            writer.text(view.detail, tone(context, node.tone, .ink));
        },
        .group, .meter_row, .callout, .actions, .button, .divider => {},
    }

    return writer.x - at.x;
}

fn drawMetric(writer: *Writer, view: data.NodeView) void {
    const context = writer.context;
    const name = view.node.metric;
    const metrics = view.facts.metrics;
    if (!data.bar_metrics.available(name, metrics)) {
        return;
    }

    const style = tone(context, data.bar_metrics.tone(name, metrics), .ink);
    switch (name) {
        .battery => {
            writer.icon(batteryIcon(data.bar_metrics.percent(name, metrics)), style);
            writer.space();
        },
        .memory, .cpu => {
            writer.text(data.bar_metrics.label(name), quiet(context));
            writer.space();
            if (name == .cpu and view.facts.cpu.len != 0) {
                writer.sparkline(view.facts.cpu, tone(context, data.bar_metrics.tone(name, metrics), .mark));
                writer.space();
            }
        },
    }

    var buffer: [data.bar_metrics.max_value_bytes]u8 = undefined;
    writer.text(data.bar_metrics.value(&buffer, name, metrics), style);
}

fn batteryIcon(percent: u8) data.icons.Icon {
    return switch (percent) {
        0...12 => .battery_empty,
        13...37 => .battery_quarter,
        38...62 => .battery_half,
        63...87 => .battery_three_quarters,
        else => .battery_full,
    };
}

/// Writes cells left to right, clipped to its area.
const Writer = struct {
    context: *Context,
    area: cellgrid.Rect,
    x: u16,

    fn text(self: *Writer, value: []const u8, style: cellgrid.Style) void {
        const limit = self.area.x + self.area.w;
        if (self.x >= limit or value.len == 0) {
            return;
        }

        self.x += self.context.buffer.writeTruncated(self.area, .{ .point = .{ .x = self.x, .y = self.area.y }, .text = value, .max_width = limit - self.x, .style = style });
    }

    fn space(self: *Writer) void {
        self.x += 1;
    }

    fn icon(self: *Writer, value: data.icons.Icon, style: cellgrid.Style) void {
        self.x += self.context.drawIcon(.{ .area = self.area, .point = .{ .x = self.x, .y = self.area.y }, .icon = value, .style = style });
    }

    fn track(self: *Writer, value: u16, style: cellgrid.Style) void {
        const filled = (@as(u32, value) * track_cells + data.Node.full_scale / 2) / data.Node.full_scale;
        for (0..track_cells) |cell| {
            self.text(if (cell < filled) track_full else track_empty, style);
        }
    }

    fn sparkline(self: *Writer, samples: []const u8, style: cellgrid.Style) void {
        const shown = samples[samples.len -| sparkline_cells..];
        for (shown) |sample| {
            const level = @min(sparkline_levels.len - 1, @as(u32, sample) * sparkline_levels.len / (full_percent + 1));
            self.text(sparkline_levels[level], style);
        }
    }
};

fn labelStyle(context: *const Context, node: data.Node) cellgrid.Style {
    const configured = node.style;
    return .{
        .fg = if (configured.foreground) |color| resolveColor(context, color) else roleColor(context, node.tone.inkRole()),
        .bg = if (configured.background) |color| resolveColor(context, color) else context.palette.panel_bg,
        .flags = .{
            .bold = configured.bold,
            .italic = configured.italic,
            .faint = configured.faint,
            .underline = if (configured.underline) .single else .none,
            .strikethrough = configured.strikethrough,
        },
    };
}

const Ink = enum {
    ink,
    mark,
};

fn tone(context: *const Context, value: data.Tone, ink: Ink) cellgrid.Style {
    return .{
        .fg = roleColor(context, switch (ink) {
            .ink => value.inkRole(),
            .mark => value.markRole(),
        }),
        .bg = context.palette.panel_bg,
    };
}

fn plain(context: *const Context) cellgrid.Style {
    return .{ .fg = context.palette.text, .bg = context.palette.panel_bg };
}

fn quiet(context: *const Context) cellgrid.Style {
    return .{ .fg = context.palette.subtext0, .bg = context.palette.panel_bg };
}

fn resolveColor(context: *const Context, color: data.bar_values.Color) cellgrid.Color {
    return switch (color) {
        .value => |value| value,
        .palette => |role| roleColor(context, role),
    };
}

fn roleColor(context: *const Context, role: data.bar_values.PaletteColor) cellgrid.Color {
    return switch (role) {
        inline else => |value| @field(context.palette, @tagName(value)),
    };
}

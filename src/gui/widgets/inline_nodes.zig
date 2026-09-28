//! Measures and paints one inline component in a pixel row: labels, icons,
//! marks, meters, sparklines, badges, clocks and metrics. Sizes are logical
//! pixels scaled by the chrome, so every configured bar shares one rhythm.
const TrackPaint = @import("TrackPaint.zig");
const InlinePlacement = @import("InlinePlacement.zig");
const cellgrid = @import("cellgrid");
const data = @import("model");
const gfx = @import("gfx");
const std = @import("std");
const Rect = gfx.Rect;
const Canvas = @import("Canvas.zig");
const Label = @import("Label.zig");
const bar_tone = @import("bar_tone.zig");

pub const group_padding: f32 = 6;
pub const child_gap: f32 = 6;
pub const row_height: f32 = 20;
const part_gap: f32 = 5;
const mark_side: f32 = 14;
const track_width: f32 = 24;
const track_height: f32 = 3;
const sparkline_bar: f32 = 2;
const sparkline_gap: f32 = 1;
const sparkline_height: f32 = 12;
/// An idle sample still shows as a short column above its track.
const sparkline_floor: f32 = 2;
const sparkline_bars = 9;
const badge_padding: f32 = 6;
const badge_height: f32 = 16;
const badge_radius: f32 = 4;
const badge_alpha: f32 = 0.16;
const battery_width: f32 = 17;
const battery_height: f32 = 10;
const battery_tip: f32 = 2;
const full_percent: f32 = 100;
const marker_width: f32 = 2;
const marker_height: f32 = 8;
const marker_alpha: f32 = 0.55;
const battery_radius: f32 = 2.5;
const battery_inset: f32 = 2;
const battery_fill_radius: f32 = 1.2;
/// The terminal's cap sits across the middle two fifths of the body.
const battery_cap_top: f32 = 0.3;
const battery_cap_height: f32 = 0.4;
const battery_cap_width: f32 = 0.75;
const full_scale: f32 = @floatFromInt(data.Node.full_scale);
/// Logical pixels between two machines, and bytes of one CPU reading.
const machine_gap: f32 = 12;
const machine_cpu_bytes = 8;

/// The width of a leaf at `level`, zero when it shows nothing.
/// Example: `const width = try inline_nodes.width(canvas, view, .full);`
pub fn width(canvas: *Canvas, view: data.NodeView, level: data.FitLevel) !f32 {
    if (level == .hidden) {
        return 0;
    }

    const chrome = canvas.chrome;
    const node = view.node;
    return switch (node.kind) {
        .label, .heading, .text => try labelWidth(canvas, view.text, labelOf(canvas, view)),
        .icon => canvas.iconSize(caption("")),
        .mark => chrome.px(mark_side),
        .meter => try meterWidth(canvas, view, level),
        .sparkline => sparklineWidth(canvas, view.samples.len),
        .badge => try canvas.measure(badgeLabel(canvas, view)) + 2 * chrome.px(badge_padding),
        .clock => clock: {
            var buffer: [data.bar_clock.max_output_bytes]u8 = undefined;
            break :clock try canvas.measure(value(clockText(&buffer, view), .neutral, canvas));
        },
        .metric => try metricWidth(canvas, view),
        .machines => try machinesWidth(canvas, view),
        .kv => try canvas.measure(caption(view.text)) + chrome.px(part_gap) + try canvas.measure(value(view.detail, node.tone, canvas)),
        .group, .meter_row, .callout, .actions, .button, .divider => 0,
    };
}

/// The group's own width without its children: padding and its mark.
/// Example: `input.full[slot][index] = inline_nodes.groupChrome(canvas, view);`
pub fn groupChrome(canvas: *const Canvas, view: data.NodeView) f32 {
    const chrome = canvas.chrome;
    const marked = view.node.mark != null or view.node.icon != null;
    const leading = if (marked) chrome.px(mark_side) else -chrome.px(child_gap);
    return 2 * chrome.px(group_padding) + leading;
}

/// Paints a leaf at `level`, vertically centred in `bounds`.
/// Example: `try inline_nodes.draw(canvas, view, .{ .bounds = cell, .level = .full });`
pub fn draw(canvas: *Canvas, view: data.NodeView, placement: InlinePlacement) !void {
    if (placement.level == .hidden or placement.bounds.width <= 0) {
        return;
    }

    const bounds = placement.bounds;
    const node = view.node;
    switch (node.kind) {
        .label, .heading, .text => {
            if (node.style.background) |background| {
                try canvas.fillAt(bounds, bar_tone.color(canvas, background));
            }

            try drawLabel(canvas, view.text, .{ .bounds = bounds, .label = labelOf(canvas, view) });
        },
        .icon => try drawIcon(canvas, view, bounds),
        .mark => try drawMark(canvas, node.mark orelse .telar, bounds),
        .meter => try drawMeter(canvas, view, placement),
        .sparkline => try drawSparkline(canvas, .{ .samples = view.samples, .tone = node.tone, .bounds = bounds }),
        .badge => try drawBadge(canvas, view, bounds),
        .clock => {
            var buffer: [data.bar_clock.max_output_bytes]u8 = undefined;
            _ = try canvas.textAt(bounds, value(clockText(&buffer, view), node.tone, canvas));
        },
        .metric => try drawMetric(canvas, view, bounds),
        .machines => try drawMachines(canvas, view, bounds),
        .kv => {
            const key = try canvas.textAt(bounds, caption(view.text));
            const gap = key + canvas.chrome.px(part_gap);
            _ = try canvas.textAt(shift(bounds, gap), value(view.detail, node.tone, canvas));
        },
        .group, .meter_row, .callout, .actions, .button, .divider => {},
    }
}

/// A group's or a panel's mark: the embedded provider sprite, else the
/// matching icon glyph.
/// Example: `try inline_nodes.drawMark(canvas, .claude, box);`
pub fn drawMark(canvas: *Canvas, mark: data.Mark, bounds: Rect) !void {
    const side = @min(canvas.chrome.px(mark_side), @min(bounds.width, bounds.height));
    const box: Rect = .{
        .x = bounds.x,
        .y = bounds.y + (bounds.height - side) / 2,
        .width = side,
        .height = side,
    };
    if (mark.provider()) |provider| {
        if (canvas.providerMark(provider)) |sprite| {
            return canvas.spriteAt(box, sprite);
        }
    }

    try canvas.iconAt(box, .{
        .text = mark.icon().nerdGlyph(),
        .color = canvas.theme.palette.text,
        .face = .sans,
        .size = .small,
    });
}

/// A caption: the short semibold label before a value.
pub fn caption(text: []const u8) Label {
    return .{
        .text = text,
        .bold = true,
        .face = .sans,
        .size = .small,
    };
}

/// The value of a component in its tone.
pub fn value(text: []const u8, tone: data.Tone, canvas: *const Canvas) Label {
    return .{
        .text = text,
        .color = bar_tone.ink(canvas, tone),
        .face = .sans,
        .size = .small,
    };
}

pub fn captionColored(canvas: *const Canvas, text: []const u8) Label {
    var label = caption(text);
    label.color = canvas.theme.palette.subtext0;
    return label;
}

/// A track of `fraction` with an optional marker, the meter shape shared by
/// the bar and panels.
/// Example: `try inline_nodes.drawTrack(canvas, .{ .bounds = track, .value = 220, .tone = .neutral });`
pub fn drawTrack(canvas: *Canvas, track: TrackPaint) !void {
    const palette = canvas.theme.palette;
    const bounds = track.bounds;
    const radius = bounds.height / 2;
    try canvas.fillRoundedAt(bounds, .{ .radius = radius, .color = palette.surface1 });
    const filled = bounds.width * @as(f32, @floatFromInt(track.value)) / full_scale;
    if (filled > 0) {
        try canvas.fillRoundedAt(.{
            .x = bounds.x,
            .y = bounds.y,
            .width = @max(filled, bounds.height),
            .height = bounds.height,
        }, .{ .radius = radius, .color = bar_tone.mark(canvas, track.tone) });
    }

    const marker = track.marker orelse return;
    const x = bounds.x + bounds.width * @as(f32, @floatFromInt(marker)) / full_scale;
    const reach = track.marker_height;
    const thickness = canvas.chrome.px(marker_width);
    try canvas.fillRoundedAt(.{
        .x = @round(x - thickness / 2),
        .y = bounds.y + (bounds.height - reach) / 2,
        .width = thickness,
        .height = reach,
    }, .{ .radius = thickness / 2, .color = palette.text, .alpha = marker_alpha });
}

/// A meter's displayed value: its own text, else its percentage.
/// Example: `const text = inline_nodes.meterText(&buffer, view);`
pub fn meterText(buffer: *[8]u8, view: data.NodeView) []const u8 {
    if (view.detail.len != 0) {
        return view.detail;
    }

    return std.fmt.bufPrint(buffer, "{d}%", .{view.node.percent()}) catch "";
}

/// A label with Nerd Font glyphs mixed into its text paints each glyph as an
/// icon, so legacy segments keep working without a patched font.
fn labelWidth(canvas: *Canvas, text: []const u8, label: Label) !f32 {
    var total: f32 = 0;
    var run_start: usize = 0;
    var iterator: cellgrid.GraphemeIterator = .{ .bytes = text };
    var offset: usize = 0;
    while (iterator.next()) |cluster| {
        defer offset += cluster.bytes.len;
        if (!isIcon(cluster.bytes)) {
            continue;
        }

        total += try measureRun(canvas, label, text[run_start..offset]);
        total += canvas.iconSize(label);
        run_start = offset + cluster.bytes.len;
    }

    return total + try measureRun(canvas, label, text[run_start..]);
}

fn drawLabel(canvas: *Canvas, text: []const u8, painted: PaintedLabel) !void {
    var bounds = painted.bounds;
    var run_start: usize = 0;
    var iterator: cellgrid.GraphemeIterator = .{ .bytes = text };
    var offset: usize = 0;
    while (iterator.next()) |cluster| {
        defer offset += cluster.bytes.len;
        if (!isIcon(cluster.bytes)) {
            continue;
        }

        bounds = shift(bounds, try paintRun(canvas, text[run_start..offset], .{ .bounds = bounds, .label = painted.label }));
        var icon = painted.label;
        icon.text = cluster.bytes;
        const side = canvas.iconSize(icon);
        try canvas.iconAt(.{ .x = bounds.x, .y = bounds.y, .width = side, .height = bounds.height }, icon);
        bounds = shift(bounds, side);
        run_start = offset + cluster.bytes.len;
    }

    _ = try paintRun(canvas, text[run_start..], .{ .bounds = bounds, .label = painted.label });
}

const PaintedLabel = struct {
    bounds: Rect,
    label: Label,
};

fn measureRun(canvas: *Canvas, label: Label, text: []const u8) !f32 {
    if (text.len == 0) {
        return 0;
    }

    var run = label;
    run.text = text;
    return canvas.measure(run);
}

fn paintRun(canvas: *Canvas, text: []const u8, painted: PaintedLabel) !f32 {
    if (text.len == 0) {
        return 0;
    }

    var run = painted.label;
    run.text = text;
    return canvas.textAt(painted.bounds, run);
}

fn labelOf(canvas: *const Canvas, view: data.NodeView) Label {
    const style = view.node.style;
    var label = value(view.text, view.node.tone, canvas);
    if (style.foreground) |foreground| {
        label.color = bar_tone.color(canvas, foreground);
    }

    label.bold = style.bold;
    label.italic = style.italic;
    label.faint = style.faint;
    label.underline = style.underline;
    label.strikethrough = style.strikethrough;
    return label;
}

fn drawIcon(canvas: *Canvas, view: data.NodeView, bounds: Rect) !void {
    const glyph = if (view.node.icon) |icon| icon.nerdGlyph() else view.text;
    var label = caption(glyph);
    label.bold = false;
    label.color = bar_tone.mark(canvas, view.node.tone);
    const side = canvas.iconSize(label);
    try canvas.iconAt(.{ .x = bounds.x, .y = bounds.y, .width = side, .height = bounds.height }, label);
}

fn meterWidth(canvas: *Canvas, view: data.NodeView, level: data.FitLevel) !f32 {
    const chrome = canvas.chrome;
    var buffer: [8]u8 = undefined;
    var total = try canvas.measure(value(meterText(&buffer, view), view.node.tone, canvas));
    if (view.text.len != 0) {
        total += try canvas.measure(caption(view.text)) + chrome.px(part_gap);
    }
    if (level == .full) {
        total += chrome.px(track_width) + chrome.px(part_gap);
    }

    return total;
}

fn drawMeter(canvas: *Canvas, view: data.NodeView, placement: InlinePlacement) !void {
    const chrome = canvas.chrome;
    var bounds = placement.bounds;
    if (view.text.len != 0) {
        const painted = try canvas.textAt(bounds, captionColored(canvas, view.text));
        bounds = shift(bounds, painted + chrome.px(part_gap));
    }
    if (placement.level == .full) {
        const height = chrome.px(track_height);
        try drawTrack(canvas, .{
            .bounds = .{
                .x = bounds.x,
                .y = @round(bounds.y + (bounds.height - height) / 2),
                .width = chrome.px(track_width),
                .height = height,
            },
            .value = view.node.value,
            .tone = view.node.tone,
            .marker = view.node.marker,
            .marker_height = chrome.px(marker_height),
        });
        bounds = shift(bounds, chrome.px(track_width) + chrome.px(part_gap));
    }

    var buffer: [8]u8 = undefined;
    _ = try canvas.textAt(bounds, value(meterText(&buffer, view), view.node.tone, canvas));
}

fn sparklineWidth(canvas: *const Canvas, samples: usize) f32 {
    const count: f32 = @floatFromInt(@min(samples, sparkline_bars));
    if (count == 0) {
        return 0;
    }

    const chrome = canvas.chrome;
    return count * chrome.px(sparkline_bar) + (count - 1) * chrome.px(sparkline_gap);
}

fn drawSparkline(canvas: *Canvas, sparkline: Sparkline) !void {
    const chrome = canvas.chrome;
    const shown = sparkline.samples[sparkline.samples.len -| sparkline_bars..];
    const height = chrome.px(sparkline_height);
    const bottom = sparkline.bounds.y + (sparkline.bounds.height + height) / 2;
    const color = bar_tone.mark(canvas, sparkline.tone);
    var x = sparkline.bounds.x;
    const radius = chrome.px(sparkline_bar) / 4;
    for (shown) |sample| {
        // A faint full-height column keeps the chart legible when idle.
        try canvas.fillRoundedAt(.{
            .x = x,
            .y = bottom - height,
            .width = chrome.px(sparkline_bar),
            .height = height,
        }, .{ .radius = radius, .color = canvas.theme.palette.surface1 });
        const bar = @max(chrome.px(sparkline_floor), @round(height * @as(f32, @floatFromInt(sample)) / full_percent));
        try canvas.fillRoundedAt(.{
            .x = x,
            .y = bottom - bar,
            .width = chrome.px(sparkline_bar),
            .height = bar,
        }, .{ .radius = radius, .color = color });
        x += chrome.px(sparkline_bar) + chrome.px(sparkline_gap);
    }
}

const Sparkline = struct {
    samples: []const u8,
    tone: data.Tone,
    bounds: Rect,
};

fn badgeLabel(canvas: *const Canvas, view: data.NodeView) Label {
    var label = value(view.text, view.node.tone, canvas);
    label.bold = true;
    return label;
}

fn drawBadge(canvas: *Canvas, view: data.NodeView, bounds: Rect) !void {
    const chrome = canvas.chrome;
    const palette = canvas.theme.palette;
    const height = chrome.px(badge_height);
    const chip: Rect = .{
        .x = bounds.x,
        .y = @round(bounds.y + (bounds.height - height) / 2),
        .width = bounds.width,
        .height = height,
    };
    const neutral = view.node.tone == .neutral or view.node.tone == .muted;
    try canvas.fillRoundedAt(chip, .{
        .radius = chrome.px(badge_radius),
        .color = if (neutral) palette.surface1 else bar_tone.mark(canvas, view.node.tone),
        .alpha = if (neutral) 1 else badge_alpha,
    });
    _ = try canvas.textAt(shift(chip, chrome.px(badge_padding)), badgeLabel(canvas, view));
}

fn metricWidth(canvas: *Canvas, view: data.NodeView) !f32 {
    const name = view.node.metric;
    const metrics = view.facts.metrics;
    if (!data.bar_metrics.available(name, metrics)) {
        return 0;
    }

    const chrome = canvas.chrome;
    var buffer: [data.bar_metrics.max_value_bytes]u8 = undefined;
    var total = try canvas.measure(value(data.bar_metrics.value(&buffer, name, metrics), .neutral, canvas));
    total += chrome.px(part_gap);
    total += switch (name) {
        .battery => chrome.px(battery_width),
        .memory => canvas.iconSize(caption("")),
        .cpu => canvas.iconSize(caption("")) + chrome.px(part_gap) + sparklineWidth(canvas, view.facts.cpu.len),
    };

    return total;
}

fn drawMetric(canvas: *Canvas, view: data.NodeView, bounds_value: Rect) !void {
    const chrome = canvas.chrome;
    const name = view.node.metric;
    const metrics = view.facts.metrics;
    const tone = data.bar_metrics.tone(name, metrics);
    var bounds = bounds_value;
    switch (name) {
        .battery => {
            try drawBattery(canvas, .{ .bounds = bounds, .percent = data.bar_metrics.percent(name, metrics), .tone = tone });
            bounds = shift(bounds, chrome.px(battery_width) + chrome.px(part_gap));
        },
        .memory, .cpu => {
            var glyph = captionColored(canvas, data.bar_metrics.icon(name).?.nerdGlyph());
            glyph.bold = false;
            const side = canvas.iconSize(glyph);
            try canvas.iconAt(.{ .x = bounds.x, .y = bounds.y, .width = side, .height = bounds.height }, glyph);
            bounds = shift(bounds, side + chrome.px(part_gap));
            if (name == .cpu and view.facts.cpu.len != 0) {
                const spark = sparklineWidth(canvas, view.facts.cpu.len);
                try drawSparkline(canvas, .{ .samples = view.facts.cpu, .tone = tone, .bounds = .{ .x = bounds.x, .y = bounds.y, .width = spark, .height = bounds.height } });
                bounds = shift(bounds, spark + chrome.px(part_gap));
            }
        },
    }

    var buffer: [data.bar_metrics.max_value_bytes]u8 = undefined;
    _ = try canvas.textAt(bounds, value(data.bar_metrics.value(&buffer, name, metrics), tone, canvas));
}

fn drawBattery(canvas: *Canvas, battery: Battery) !void {
    const chrome = canvas.chrome;
    const width_px = chrome.px(battery_width);
    const height_px = chrome.px(battery_height);
    const tip = chrome.px(battery_tip);
    const body: Rect = .{
        .x = battery.bounds.x,
        .y = @round(battery.bounds.y + (battery.bounds.height - height_px) / 2),
        .width = width_px - tip,
        .height = height_px,
    };
    const outline = if (battery.tone == .neutral) canvas.theme.palette.subtext0 else bar_tone.mark(canvas, battery.tone);
    try canvas.ringAt(body, .{ .width = chrome.px(1), .color = outline, .radius = chrome.px(battery_radius) });
    try canvas.fillRoundedAt(.{
        .x = body.x + body.width,
        .y = body.y + height_px * battery_cap_top,
        .width = tip * battery_cap_width,
        .height = height_px * battery_cap_height,
    }, .{ .radius = tip * battery_cap_width / 2, .color = outline });
    const inset = chrome.px(battery_inset);
    const inner = body.width - 2 * inset;
    const filled = inner * @as(f32, @floatFromInt(battery.percent)) / full_percent;
    if (filled > 0) {
        try canvas.fillRoundedAt(.{
            .x = body.x + inset,
            .y = body.y + inset,
            .width = @max(filled, chrome.px(1)),
            .height = body.height - 2 * inset,
        }, .{ .radius = chrome.px(battery_fill_radius), .color = if (battery.tone == .neutral) canvas.theme.palette.text else outline });
    }
}

const Battery = struct {
    bounds: Rect,
    percent: u8,
    tone: data.Tone,
};

fn clockText(buffer: *[data.bar_clock.max_output_bytes]u8, view: data.NodeView) []const u8 {
    return data.bar_clock.format(buffer, view.text, view.facts.now);
}

fn shift(bounds: Rect, by: f32) Rect {
    return .{
        .x = bounds.x + by,
        .y = bounds.y,
        .width = @max(0, bounds.width - by),
        .height = bounds.height,
    };
}

// Nerd Fonts place their icons in Unicode's private-use ranges.
fn isIcon(text: []const u8) bool {
    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    const codepoint = iterator.nextCodepoint() orelse return false;
    return (codepoint >= 0xe000 and codepoint <= 0xf8ff) or
        (codepoint >= 0xf0000 and codepoint <= 0xffffd) or
        (codepoint >= 0x100000 and codepoint <= 0x10fffd);
}

/// One entry per machine: a status glyph, the label (bold for the one
/// shown) and the CPU of a connected machine.
fn machinesWidth(canvas: *Canvas, view: data.NodeView) !f32 {
    const chrome = canvas.chrome;
    var total: f32 = 0;
    for (view.facts.machines, 0..) |fact, index| {
        if (index != 0) {
            total += chrome.px(machine_gap);
        }

        total += try machineWidth(canvas, fact);
    }

    return total;
}

fn machineWidth(canvas: *Canvas, fact: data.MachineFact) !f32 {
    const chrome = canvas.chrome;
    var buffer: [machine_cpu_bytes]u8 = undefined;
    var total = try canvas.measure(machineGlyph(canvas, fact)) + chrome.px(part_gap) + try canvas.measure(machineLabel(canvas, fact));
    if (machineCpu(&buffer, fact)) |cpu| {
        total += chrome.px(part_gap) + try canvas.measure(value(cpu, .neutral, canvas));
    }

    return total;
}

fn drawMachines(canvas: *Canvas, view: data.NodeView, bounds_value: Rect) !void {
    const chrome = canvas.chrome;
    var bounds = bounds_value;
    for (view.facts.machines, 0..) |fact, index| {
        if (index != 0) {
            bounds = shift(bounds, chrome.px(machine_gap));
        }

        bounds = shift(bounds, try canvas.textAt(bounds, machineGlyph(canvas, fact)) + chrome.px(part_gap));
        bounds = shift(bounds, try canvas.textAt(bounds, machineLabel(canvas, fact)));
        var buffer: [machine_cpu_bytes]u8 = undefined;
        if (machineCpu(&buffer, fact)) |cpu| {
            bounds = shift(bounds, chrome.px(part_gap));
            bounds = shift(bounds, try canvas.textAt(bounds, value(cpu, .neutral, canvas)));
        }
    }
}

fn machineGlyph(canvas: *const Canvas, fact: data.MachineFact) Label {
    const palette = canvas.theme.palette;
    const glyph: []const u8, const color = if (fact.attention)
        .{ "●", palette.yellow }
    else switch (fact.phase) {
        .connected => .{ "●", palette.green },
        .connecting => .{ "◌", palette.overlay1 },
        .lost => .{ "✕", palette.red },
        .stopped => .{ "○", palette.overlay0 },
    };
    return .{ .text = glyph, .color = color, .face = .sans, .size = .small };
}

fn machineLabel(canvas: *const Canvas, fact: data.MachineFact) Label {
    return .{ .text = fact.label, .color = canvas.theme.palette.text, .bold = fact.active, .face = .sans, .size = .small };
}

fn machineCpu(buffer: *[machine_cpu_bytes]u8, fact: data.MachineFact) ?[]const u8 {
    if (fact.phase != .connected) {
        return null;
    }

    const cpu = fact.cpu_percent orelse return null;
    return std.fmt.bufPrint(buffer, "{d}%", .{cpu}) catch null;
}

//! System metrics at the left edge of the bottom bar.
//!
//! The runtime samples cpu, memory, and battery off the interactive path and
//! ClientModel caches the latest values. Rendering only formats what is
//! already in memory, in fixed buffers, so the frame stays allocation free.

const ContextType = @import("Context.zig");
const RectType = @import("telar-core").Rect;
const Metrics = @import("Metrics.zig");
const StyleType = @import("telar-core").Style;
const std = @import("std");
const icons_module = @import("../ui/icons.zig");
const measure_module = @import("telar-core").measure;
const IconType = @import("telar-client").Icon;
const Mode = @import("telar-client").Mode;
const Hints = @import("telar-client").Hints;
const PairInput = @import("PairInput.zig");
const WriteInput = @import("WriteInput.zig");
const KeyType = @import("telar-client").Key;
const ColorType = @import("telar-core").Color;
const BufferType = @import("telar-core").Buffer;
const widget = @import("context_support.zig");
const theme_support = @import("telar-client").theme_support;
const parseKey_module = @import("telar-client").parseKey;

pub fn render(context: *ContextType, area: RectType, metrics: ?Metrics) void {
    if (area.isEmpty()) {
        return;
    }
    const values = metrics orelse return;
    var x = area.x + 1;
    const background = context.palette.panel_bg;

    const cpu_style: StyleType = .{
        .fg = cpuColor(context, values.cpu_percent),
        .bg = background,
    };
    x += context.drawIcon(.{ .area = area, .point = .{ .x = x, .y = area.y }, .icon = .cpu, .style = cpu_style });
    var cpu_buffer: [10]u8 = undefined;
    const cpu = std.fmt.bufPrint(&cpu_buffer, " {d}%", .{values.cpu_percent}) catch return;
    x += context.buffer.writeText(area, .{ .point = .{ .x = x, .y = area.y }, .text = cpu, .style = cpu_style });
    x += context.buffer.writeText(area, .{ .point = .{ .x = x, .y = area.y }, .text = "  ", .style = .{ .bg = background } });

    const memory_style: StyleType = .{
        .fg = context.palette.mauve,
        .bg = background,
    };
    x += context.drawIcon(.{ .area = area, .point = .{ .x = x, .y = area.y }, .icon = .memory, .style = memory_style });
    var memory_buffer: [14]u8 = undefined;
    const memory = std.fmt.bufPrint(&memory_buffer, " {d}.{d}G", .{
        values.memory_used_decigib / 10,
        values.memory_used_decigib % 10,
    }) catch return;
    x += context.buffer.writeText(area, .{ .point = .{ .x = x, .y = area.y }, .text = memory, .style = memory_style });

    // Machines without a battery show nothing rather than a fake 0%.
    if (values.battery_percent) |battery| {
        x += context.buffer.writeText(area, .{ .point = .{ .x = x, .y = area.y }, .text = "  ", .style = .{ .bg = background } });
        const battery_style: StyleType = .{
            .fg = if (battery < 20) context.palette.red else context.palette.green,
            .bg = background,
        };
        x += context.drawIcon(.{ .area = area, .point = .{ .x = x, .y = area.y }, .icon = icons_module.battery(battery), .style = battery_style });
        var battery_buffer: [10]u8 = undefined;
        const text = std.fmt.bufPrint(&battery_buffer, "{d}%", .{battery}) catch return;
        _ = context.buffer.writeText(area, .{ .point = .{ .x = x, .y = area.y }, .text = text, .style = battery_style });
    }
}

pub fn desiredWidth(metrics: ?Metrics) u16 {
    const values = metrics orelse return 0;
    var cpu_buffer: [10]u8 = undefined;
    const cpu = std.fmt.bufPrint(&cpu_buffer, " {d}%", .{values.cpu_percent}) catch return 0;
    var memory_buffer: [14]u8 = undefined;
    const memory = std.fmt.bufPrint(&memory_buffer, " {d}.{d}G", .{
        values.memory_used_decigib / 10,
        values.memory_used_decigib % 10,
    }) catch return 0;
    var width: u16 = 1 + iconWidth(.cpu) + measure_module(cpu) + 2 + iconWidth(.memory) + measure_module(memory);
    if (values.battery_percent) |battery| {
        var battery_buffer: [10]u8 = undefined;
        const text = std.fmt.bufPrint(&battery_buffer, "{d}%", .{battery}) catch return width;
        width +|= 2 + iconWidth(icons_module.battery(battery)) + measure_module(text);
    }

    return width;
}

fn iconWidth(icon: IconType) u16 {
    return @max(@as(u16, 1), measure_module(icon.unicodeGlyph()));
}

pub fn renderMode(context: *ContextType, area: RectType, mode: Mode) void {
    if (area.isEmpty() or mode == .normal) {
        return;
    }
    context.buffer.fill(area, .{ .glyph = " ", .style = .{ .bg = context.palette.panel_bg } });
    switch (mode) {
        .normal => {},
        .prefix => |hints| renderPrefix(context, area, &hints),
        .copy => renderCopy(context, area),
    }
}

fn renderPrefix(context: *ContextType, area: RectType, hints: *const Hints) void {
    var x = renderModeLabel(context, area, " PREFIX ");
    renderPair(context, .{ .area = area, .x = &x, .key = "Esc", .label = "cancel" });
    for (hints.slice()) |hint| {
        var key_buffer: [32]u8 = undefined;
        renderPair(context, .{ .area = area, .x = &x, .key = formatKey(&key_buffer, hint.key), .label = hint.label });
    }
}

fn renderCopy(context: *ContextType, area: RectType) void {
    var x = renderModeLabel(context, area, " COPY ");
    renderPair(context, .{ .area = area, .x = &x, .key = "h/j/k/l", .label = "move" });
    renderPair(context, .{ .area = area, .x = &x, .key = "w/b/e", .label = "word" });
    renderPair(context, .{ .area = area, .x = &x, .key = "g/G", .label = "ends" });
    renderPair(context, .{ .area = area, .x = &x, .key = "v/Space", .label = "select" });
    renderPair(context, .{ .area = area, .x = &x, .key = "V", .label = "lines" });
    renderPair(context, .{ .area = area, .x = &x, .key = "o", .label = "open link" });
    renderPair(context, .{ .area = area, .x = &x, .key = "y/Enter", .label = "copy" });
    renderPair(context, .{ .area = area, .x = &x, .key = "q/Esc", .label = "exit" });
}

fn renderModeLabel(context: *ContextType, area: RectType, label: []const u8) u16 {
    return area.x + context.buffer.writeTruncated(area, .{ .point = .{ .x = area.x, .y = area.y }, .text = label, .max_width = area.w, .style = .{
        .fg = context.palette.surface_dim,
        .bg = context.palette.accent,
        .flags = .{ .bold = true },
    } });
}

fn renderPair(context: *ContextType, pair: PairInput) void {
    const area = pair.area;
    const x = pair.x;

    write(context, .{ .area = area, .x = x, .text = " ", .style = .{ .bg = context.palette.panel_bg } });
    write(context, .{
        .area = area,
        .x = x,
        .text = pair.key,
        .style = .{
            .fg = context.palette.accent,
            .bg = context.palette.panel_bg,
            .flags = .{ .bold = true },
        },
    });
    write(context, .{ .area = area, .x = x, .text = " ", .style = .{ .bg = context.palette.panel_bg } });
    write(context, .{
        .area = area,
        .x = x,
        .text = pair.label,
        .style = .{
            .fg = context.palette.overlay0,
            .bg = context.palette.panel_bg,
        },
    });
    write(context, .{ .area = area, .x = x, .text = " ", .style = .{ .bg = context.palette.panel_bg } });
}

fn write(context: *ContextType, input_write: WriteInput) void {
    const remaining = input_write.area.x + input_write.area.w -| input_write.x.*;
    if (remaining == 0) {
        return;
    }
    input_write.x.* += context.buffer.writeTruncated(input_write.area, .{
        .point = .{ .x = input_write.x.*, .y = input_write.area.y },
        .text = input_write.text,
        .max_width = remaining,
        .style = input_write.style,
    });
}

fn formatKey(buffer: *[32]u8, key: KeyType) []const u8 {
    var len: usize = 0;
    if (key.mods.ctrl) {
        append(buffer, &len, "Ctrl+");
    }
    if (key.mods.alt) {
        append(buffer, &len, "Alt+");
    }
    if (key.mods.shift) {
        append(buffer, &len, "Shift+");
    }
    const code: []const u8 = switch (key.code) {
        .char => |char| char.slice(),
        .up => "Up",
        .down => "Down",
        .left => "Left",
        .right => "Right",
        .home => "Home",
        .end => "End",
        .delete => "Del",
        .page_up => "PgUp",
        .page_down => "PgDn",
        .enter => "Enter",
        .escape => "Esc",
        .backspace => "Backspace",
        .tab => "Tab",
        .back_tab => "Shift+Tab",
    };
    append(buffer, &len, code);
    return buffer[0..len];
}

fn append(buffer: *[32]u8, len: *usize, text: []const u8) void {
    const take = @min(text.len, buffer.len - len.*);
    @memcpy(buffer[len.*..][0..take], text[0..take]);
    len.* += take;
}

fn cpuColor(context: *const ContextType, cpu_percent: u8) ColorType {
    if (cpu_percent > 90) {
        return context.palette.red;
    }
    if (cpu_percent > 70) {
        return context.palette.yellow;
    }
    return context.palette.teal;
}

test "mode bars render prefix and copy hints" {
    var buffer = try BufferType.init(std.testing.allocator, 120, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: ContextType = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &theme_support.default_theme.palette,
        .hovered = null,
    };
    var hints: Hints = .{};
    hints.append(.{ .key = try parseKey_module("N"), .label = "new workspace" });

    renderMode(&context, buffer.area(), .{ .prefix = hints });
    try std.testing.expectEqualStrings("P", buffer.at(1, 0).?.text());
    try std.testing.expectEqualStrings("E", buffer.at(9, 0).?.text());

    renderMode(&context, buffer.area(), .copy);
    try std.testing.expectEqualStrings("C", buffer.at(1, 0).?.text());
    try std.testing.expectEqualStrings("h", buffer.at(7, 0).?.text());
}

test "key labels preserve modifiers and special keys" {
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "Ctrl+Alt+Left",
        formatKey(&buffer, try parseKey_module("ctrl+alt+left")),
    );
}

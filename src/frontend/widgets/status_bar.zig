//! The bottom row in prefix and copy mode: the mode label and key hints.
const keyinput = @import("keyinput");

const cellgrid = @import("cellgrid");
const client = @import("telar-client");
const data = @import("model");
const Context = @import("Context.zig");
const std = @import("std");
const widget = @import("context_support.zig");

pub fn renderMode(context: *Context, area: cellgrid.Rect, mode: client.Mode) void {
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

fn renderPrefix(context: *Context, area: cellgrid.Rect, hints: *const client.Hints) void {
    var x = renderModeLabel(context, area, " PREFIX ");
    renderPair(context, .{ .area = area, .x = &x, .key = "Esc", .label = "cancel" });
    for (hints.slice()) |hint| {
        var key_buffer: [32]u8 = undefined;
        renderPair(context, .{ .area = area, .x = &x, .key = formatKey(&key_buffer, hint.key), .label = hint.label });
    }
}

fn renderCopy(context: *Context, area: cellgrid.Rect) void {
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

fn renderModeLabel(context: *Context, area: cellgrid.Rect, label: []const u8) u16 {
    return area.x + context.buffer.writeTruncated(area, .{ .point = .{ .x = area.x, .y = area.y }, .text = label, .max_width = area.w, .style = .{
        .fg = context.palette.surface_dim,
        .bg = context.palette.accent,
        .flags = .{ .bold = true },
    } });
}

fn renderPair(context: *Context, pair: PairInput) void {
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

fn write(context: *Context, input_write: WriteInput) void {
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

fn formatKey(buffer: *[32]u8, key: keyinput.Key) []const u8 {
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

test "mode bars render prefix and copy hints" {
    var buffer = try cellgrid.Buffer.init(std.testing.allocator, 120, 1);
    defer buffer.deinit();
    var hits: widget.Hits = .{};
    var context: Context = .{
        .buffer = &buffer,
        .hits = &hits,
        .palette = &data.theme_support.default_theme.palette,
        .hovered = null,
    };
    var hints: client.Hints = .{};
    hints.append(.{ .key = try keyinput.chord.parseKey("N"), .label = "new workspace" });

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
        formatKey(&buffer, try keyinput.chord.parseKey("ctrl+alt+left")),
    );
}

const WriteInput = struct {
    area: cellgrid.Rect,
    x: *u16,
    text: []const u8,
    style: cellgrid.Style,
};

const PairInput = struct {
    area: cellgrid.Rect,
    x: *u16,
    key: []const u8,
    label: []const u8,
};

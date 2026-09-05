//! Emits an SVG of the actual history widget's cells for visual regression review.
//! Run `zig build history-preview -- --inspect` and redirect stdout to a local SVG.

const std = @import("std");
const frontend = @import("telar-frontend");
const ui = frontend.ui;
const browser = frontend.widgets.history_browser;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var inspecting = false;
    var narrow = false;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "--inspect")) {
            inspecting = true;
        } else if (std.mem.eql(u8, arg, "--narrow")) {
            narrow = true;
        }
    }

    var buffer = try ui.Buffer.init(init.gpa, if (narrow) 56 else 150, 36);
    defer buffer.deinit();
    const palette = &ui.theme.default_theme.palette;
    buffer.fill(buffer.area(), .{ .glyph = " ", .style = .{ .bg = palette.surface_dim } });
    var hits: frontend.widgets.Hits = .{};
    var context: frontend.widgets.Context = .{ .buffer = &buffer, .hits = &hits, .palette = palette, .hovered = null };
    var field: frontend.widgets.goto_picker.Field = .init("zig");
    const commands = [_][]const u8{ "zig build test", "zig build -Doptimize=ReleaseFast", "zig fmt src/frontend/widgets/history_browser.zig", "zig build test-frontend", "zig build codestyle", "zig version" };
    var entries: [commands.len]browser.Entry = undefined;
    for (commands, 0..) |command, index| {
        entries[index] = .{ .id = 240 - index, .pane_id = @enumFromInt(7), .command = command, .cwd = "/Users/adrian/sandbox/telar", .started_at_ms = 1788600000000 - @as(i64, @intCast(index)) * 3600000, .duration_ns = 1800000000, .exit_code = if (index == 1) 1 else 0, .status = .completed, .author = .human };
    }

    _ = browser.render(&context, buffer.area(), .{ .field = &field, .entries = &entries, .selection = 0, .scope = "global", .inspecting = inspecting, .now_ms = 1788600120000, .output_hint = "Captured output", .output = "Build Summary: 82/82 steps succeeded\n3298 tests passed\n\nAll checks completed." });
    var output_buffer: [16384]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    const writer = &output.interface;
    try writer.print("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"{d}\" height=\"{d}\" font-family=\"JetBrains Mono,monospace\" font-size=\"15\">", .{ buffer.area().w * 10, buffer.area().h * 22 });
    for (0..buffer.area().h) |y| {
        for (0..buffer.area().w) |x| {
            const cell = buffer.at(@intCast(x), @intCast(y)).?;
            const bg = rgb(cell.style.bg);
            const fg = rgb(cell.style.fg);
            try writer.print("<rect x=\"{d}\" y=\"{d}\" width=\"10\" height=\"22\" fill=\"#{x:0>6}\"/>", .{ x * 10, y * 22, bg });
            try writer.print("<text x=\"{d}\" y=\"{d}\" fill=\"#{x:0>6}\" xml:space=\"preserve\">", .{ x * 10, y * 22 + 17, fg });
            try xml(writer, cell.text());
            try writer.writeAll("</text>");
        }
    }

    try writer.writeAll("</svg>\n");
    try writer.flush();
}

fn rgb(color: ui.Color) u24 {
    return switch (color) {
        .rgb => |value| (@as(u24, value[0]) << 16) | (@as(u24, value[1]) << 8) | value[2],
        else => 0xffffff,
    };
}

fn xml(writer: *std.Io.Writer, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '&' => try writer.writeAll("&amp;"),
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            else => try writer.writeByte(byte),
        }
    }
}

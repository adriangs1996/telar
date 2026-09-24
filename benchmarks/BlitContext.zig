//! A VT screen shaped like a syntax-highlighted editor, blitted in full into
//! the runtime's cell buffer: the per-cell cost of `vt.RenderState` to `Cell`.
const vtgrid = @import("vtgrid");
const cellgrid = @import("cellgrid");
const backend = @import("telar-backend");
const std = @import("std");
const vt = @import("ghostty-vt");
const main = @import("main.zig");
const BlitContext = @This();

gpa: std.mem.Allocator,
terminal: vt.Terminal,
state: vt.RenderState,
buffer: cellgrid.Buffer,

pub fn init(gpa: std.mem.Allocator, io: std.Io) !BlitContext {
    var terminal = try vt.Terminal.init(io, gpa, .{ .cols = main.cols, .rows = main.rows });
    errdefer terminal.deinit(gpa);
    var state: vt.RenderState = .empty;
    errdefer state.deinit(gpa);
    var buffer = try cellgrid.Buffer.init(gpa, main.cols, main.rows);
    errdefer buffer.deinit();

    var stream = terminal.vtStream();
    defer stream.deinit();
    const palette = [_][]const u8{ "\x1b[0m", "\x1b[38;5;4m", "\x1b[1;38;2;200;120;40m", "\x1b[3;32m", "\x1b[38;5;245;48;5;236m" };
    var line: [512]u8 = undefined;
    for (0..main.rows) |row| {
        var writer = std.Io.Writer.fixed(&line);
        try writer.print("\x1b[{d};1H", .{row + 1});
        var column: usize = 0;
        var token: usize = row;
        while (column + 8 <= main.cols) : (column += 8) {
            try writer.writeAll(palette[token % palette.len]);
            try writer.writeAll(if (token % 7 == 0) "é—λ→  " else "token_  ");
            token += 3;
        }
        stream.nextSlice(writer.buffered());
    }

    try state.update(gpa, &terminal);
    return .{
        .gpa = gpa,
        .terminal = terminal,
        .state = state,
        .buffer = buffer,
    };
}

pub fn deinit(self: *BlitContext) void {
    self.buffer.deinit();
    self.state.deinit(self.gpa);
    self.terminal.deinit(self.gpa);
}

/// Copies every row regardless of damage. Example: `const copied = context.blitAll();`
pub fn blitAll(self: *BlitContext) u64 {
    const stats = vtgrid.blit(.{
        .buffer = &self.buffer,
        .area = self.buffer.area(),
        .terminal = &self.terminal,
        .state = &self.state,
        .options = .{ .force = true },
    });
    return stats.copied + self.buffer.cells[main.cols + 3].len;
}

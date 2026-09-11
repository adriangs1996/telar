const vt = @import("ghostty-vt");
const std = @import("std");
/// A pane, driven by writing to it the way an agent would.
///
/// No pty and no process: the emulator takes bytes, so a test can produce any
/// screen state a real agent could by writing the same escape sequences.
const Pane = @This();

term: vt.Terminal,
state: vt.RenderState,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Pane {
    return .{
        .term = try vt.Terminal.init(std.testing.io, gpa, .{ .cols = cols, .rows = rows }),
        .state = .empty,
        .gpa = gpa,
    };
}

pub fn deinit(p: *Pane) void {
    p.state.deinit(p.gpa);
    p.term.deinit(p.gpa);
}

pub fn write(p: *Pane, bytes: []const u8) !void {
    var stream = p.term.vtStream();
    defer stream.deinit();
    stream.nextSlice(bytes);
    try p.state.update(p.gpa, &p.term);
}

const client = @import("telar-client");
const std = @import("std");
const FastWrite = @import("FastWrite.zig");
const Output = @This();

allocator: std.mem.Allocator,
target: *std.Io.Writer,
writer: std.Io.Writer,
buffers: [2][]u8,
active: u1 = 0,
pending: bool = false,
delivery: ?client.Token = null,
draw_deferred: bool = false,
media_deferred: bool = false,
fast_write: ?FastWrite = null,

pub const Work = @import("Work.zig");

/// Allocates two bounded buffers once; the client must keep Output stable.
/// Example: `var output = try Output.init(gpa, host_writer);`.
pub fn init(allocator: std.mem.Allocator, target: *std.Io.Writer) !Output {
    const first = try allocator.alloc(u8, 512 * 1024);
    errdefer allocator.free(first);
    const second = try allocator.alloc(u8, 512 * 1024);
    return .{ .allocator = allocator, .target = target, .buffers = .{ first, second }, .writer = .fixed(first) };
}

/// Grows only the writable buffer at a geometry transition, never in flight.
/// Example: `try output.prepareFrame(width * height);`.
pub fn prepareFrame(self: *Output, cells: usize) !void {
    std.debug.assert(!self.pending);
    const required = @max(512 * 1024, cells * 96 + 512 * 1024);
    if (required > 16 * 1024 * 1024) {
        return error.HostFrameTooLarge;
    }
    if (required <= self.writer.buffer.len) {
        return;
    }

    const buffer = try self.allocator.realloc(self.buffers[self.active], required);
    self.buffers[self.active] = buffer;
    self.writer.buffer = buffer;
}

/// Seals bytes without copying. The returned borrow ends at complete().
/// Example: `const work = output.begin() orelse return;`.
pub fn begin(self: *Output) ?Work {
    if (self.pending or self.writer.end == 0) {
        return null;
    }

    const bytes = self.writer.buffered();
    self.active ^= 1;
    self.writer = .fixed(self.buffers[self.active]);
    self.pending = true;
    return .{ .target = self.target, .bytes = bytes };
}

/// Attempts one nonblocking prefix before handing the remaining bytes off.
/// Example: `const remaining = try output.tryWrite(work);`.
pub fn tryWrite(self: *Output, work: Work) !Work {
    std.debug.assert(self.pending);
    const fast = self.fast_write orelse return work;
    const written = try fast.write(fast.context, work.bytes);
    if (written > work.bytes.len) {
        return error.InvalidWriteCount;
    }

    return .{ .target = work.target, .bytes = work.bytes[written..] };
}

/// Ends the borrow before propagating failure. Failed writes never retire damage.
/// Example: `const delivery = try output.complete(result);`.
pub fn complete(self: *Output, result: anyerror!void) !?client.Token {
    std.debug.assert(self.pending);
    self.pending = false;
    const delivery = self.delivery;
    self.delivery = null;
    try result;
    return delivery;
}

/// Releases storage after cancelling and joining the output actor.
/// Example: `output.deinit();`.
pub fn deinit(self: *Output) void {
    for (self.buffers) |buffer| {
        self.allocator.free(buffer);
    }
}

/// Runs exclusively on the host-output actor.
/// Example: `try Output.write(work);`.
pub fn write(work: Work) anyerror!void {
    try work.target.writeAll(work.bytes);
    try work.target.flush();
}

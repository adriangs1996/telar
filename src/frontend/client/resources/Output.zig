const Output = @This();
const std = @import("std");
const source_namespace = @import("host_output.zig");
const presenter = @import("../presentation/Presenter.zig");
const FastWrite = @import("FastWrite.zig");
allocator: std.mem.Allocator,
target: *source_namespace.Io.Writer,
writer: source_namespace.Io.Writer,
buffers: [2][]u8,
active: u1 = 0,
pending: bool = false,
delivery: ?presenter.Token = null,
draw_deferred: bool = false,
media_deferred: bool = false,
fast_write: ?FastWrite = null,

pub const Work = struct {
    target: *source_namespace.Io.Writer,
    bytes: []const u8,
};

/// Allocates two bounded buffers once; the client must keep Output stable.
/// Example: `var output = try Output.init(gpa, host_writer);`.
pub fn init(allocator: std.mem.Allocator, target: *source_namespace.Io.Writer) !Output {
    const first = try allocator.alloc(u8, 512 * 1024);
    errdefer allocator.free(first);
    const second = try allocator.alloc(u8, 512 * 1024);
    return .{ .allocator = allocator, .target = target, .buffers = .{ first, second }, .writer = .fixed(first) };
}

/// Grows only the writable buffer at a geometry transition, never in flight.
/// Example: `try output.prepareFrame(width * height);`.
pub fn prepareFrame(output: *Output, cells: usize) !void {
    std.debug.assert(!output.pending);
    const required = @max(512 * 1024, cells * 96 + 512 * 1024);
    if (required > 16 * 1024 * 1024) {
        return error.HostFrameTooLarge;
    }
    if (required <= output.writer.buffer.len) {
        return;
    }

    const buffer = try output.allocator.realloc(output.buffers[output.active], required);
    output.buffers[output.active] = buffer;
    output.writer.buffer = buffer;
}

/// Seals bytes without copying. The returned borrow ends at complete().
/// Example: `const work = output.begin() orelse return;`.
pub fn begin(output: *Output) ?Work {
    if (output.pending or output.writer.end == 0) {
        return null;
    }

    const bytes = output.writer.buffered();
    output.active ^= 1;
    output.writer = .fixed(output.buffers[output.active]);
    output.pending = true;
    return .{ .target = output.target, .bytes = bytes };
}

/// Attempts one nonblocking prefix before handing the remaining bytes off.
/// Example: `const remaining = try output.tryWrite(work);`.
pub fn tryWrite(output: *Output, work: Work) !Work {
    std.debug.assert(output.pending);
    const fast = output.fast_write orelse return work;
    const written = try fast.write(fast.context, work.bytes);
    if (written > work.bytes.len) {
        return error.InvalidWriteCount;
    }

    return .{ .target = work.target, .bytes = work.bytes[written..] };
}

/// Ends the borrow before propagating failure. Failed writes never ACK.
/// Example: `const delivery = try output.complete(result);`.
pub fn complete(output: *Output, result: anyerror!void) !?presenter.Token {
    std.debug.assert(output.pending);
    output.pending = false;
    const delivery = output.delivery;
    output.delivery = null;
    try result;
    return delivery;
}

/// Releases storage after cancelling and joining the output actor.
/// Example: `output.deinit();`.
pub fn deinit(output: *Output) void {
    for (output.buffers) |buffer| {
        output.allocator.free(buffer);
    }
}

/// Runs exclusively on the host-output actor.
/// Example: `try Output.write(work);`.
pub fn write(work: Work) anyerror!void {
    try work.target.writeAll(work.bytes);
    try work.target.flush();
}

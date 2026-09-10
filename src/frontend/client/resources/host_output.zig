//! Single-flight host output. The worker borrows only sealed bytes and a writer.
const std = @import("std");
const presenter = @import("../presentation/presenter.zig");
const Io = std.Io;

pub const FastWrite = struct {
    context: *anyopaque,
    write: *const fn (*anyopaque, []const u8) anyerror!usize,
};

pub const Output = struct {
    allocator: std.mem.Allocator,
    target: *Io.Writer,
    writer: Io.Writer,
    buffers: [2][]u8,
    active: u1 = 0,
    pending: bool = false,
    delivery: ?presenter.Token = null,
    draw_deferred: bool = false,
    media_deferred: bool = false,
    fast_write: ?FastWrite = null,

    pub const Work = struct {
        target: *Io.Writer,
        bytes: []const u8,
    };

    /// Allocates two bounded buffers once; the client must keep Output stable.
    /// Example: `var output = try Output.init(gpa, host_writer);`.
    pub fn init(allocator: std.mem.Allocator, target: *Io.Writer) !Output {
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
};

const PrefixWriter = struct {
    writer: *Io.Writer,
    limit: usize,

    fn write(context: *anyopaque, bytes: []const u8) !usize {
        const prefix: *PrefixWriter = @ptrCast(@alignCast(context));
        const count = @min(prefix.limit, bytes.len);
        try prefix.writer.writeAll(bytes[0..count]);
        return count;
    }
};

test "a nonblocking prefix and the output actor transmit each byte exactly once" {
    for ([_]usize{ 0, 2, 5 }) |limit| {
        var bytes: [64]u8 = undefined;
        var target: Io.Writer = .fixed(&bytes);
        var prefix: PrefixWriter = .{ .writer = &target, .limit = limit };
        var output = try Output.init(std.testing.allocator, &target);
        defer output.deinit();
        output.fast_write = .{ .context = &prefix, .write = PrefixWriter.write };
        output.delivery = @enumFromInt(1);
        try output.writer.writeAll("frame");
        const remaining = try output.tryWrite(output.begin().?);
        try std.testing.expectEqualStrings("frame"[limit..], remaining.bytes);
        try std.testing.expect(output.pending);
        try std.testing.expect(output.delivery != null);
        if (remaining.bytes.len != 0) {
            try Output.write(remaining);
        }
        try std.testing.expect(try output.complete({}) != null);
        try std.testing.expectEqualStrings("frame", target.buffered());
    }
}

test "sealed bytes stay immutable while sideband output accumulates" {
    var bytes: [64]u8 = undefined;
    var target: Io.Writer = .fixed(&bytes);
    var output = try Output.init(std.testing.allocator, &target);
    defer output.deinit();
    try output.writer.writeAll("first");
    const work = output.begin().?;
    try output.writer.writeAll("second");
    try std.testing.expect(output.begin() == null);
    try std.testing.expectEqualStrings("first", work.bytes);
    try Output.write(work);
    _ = try output.complete({});
    try Output.write(output.begin().?);
    _ = try output.complete({});
    try std.testing.expectEqualStrings("firstsecond", target.buffered());
}

test "a completed write releases its exact completion token" {
    var bytes: [64]u8 = undefined;
    var target: Io.Writer = .fixed(&bytes);
    var output = try Output.init(std.testing.allocator, &target);
    defer output.deinit();
    try output.writer.writeAll("frame");
    output.delivery = @enumFromInt(42);
    const work = output.begin().?;
    try std.testing.expectEqual(@as(usize, 0), target.end);
    try Output.write(work);
    const delivered = (try output.complete({})).?;
    try std.testing.expectEqual(@as(presenter.Token, @enumFromInt(42)), delivered);
    try std.testing.expect(output.delivery == null);
    try std.testing.expectError(error.HostFrameTooLarge, output.prepareFrame(1_000_000));
}

test "a failed write cannot deliver a frame acknowledgement" {
    var output = try Output.init(std.testing.allocator, undefined);
    defer output.deinit();
    try output.writer.writeAll("frame");
    output.delivery = @enumFromInt(42);
    _ = output.begin().?;
    try std.testing.expect(output.delivery != null);
    try std.testing.expectError(error.WriteFailed, output.complete(error.WriteFailed));
    try std.testing.expect(!output.pending);
    try std.testing.expect(output.delivery == null);
}

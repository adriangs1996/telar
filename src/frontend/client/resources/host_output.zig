//! Single-flight host output. The worker borrows only sealed bytes and a writer.
const std = @import("std");
const presenter = @import("../presentation/Presenter.zig");
pub const Io = std.Io;

pub const FastWrite = @import("FastWrite.zig");

pub const Output = @import("Output.zig");

const PrefixWriter = @import("PrefixWriter.zig");

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

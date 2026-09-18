const std = @import("std");
const Fixture = @import("WorkerFixture.zig");
const worker = @import("worker.zig");

const drain = "while IFS= read -r line; do :; done\n";
const spin = "while :; do :; done\n";
const close_output = "exec 1>&-\nexec 2>&-\n";
const valid_image = "printf 'TLRD\\001\\000\\000\\000\\001\\000\\000\\000\\000\\000\\200\\077\\000\\000\\200\\077\\000\\000\\000\\000\\200\\000\\000\\200'\n";

test "diagram worker adopts exact pixels and reaps a successful helper" {
    var fixture = try Fixture.init(drain ++ valid_image);
    defer fixture.deinit();
    var task = fixture.task(2000);
    var image = try worker.renderTask(&task);
    defer image.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 1), image.width);
    try std.testing.expectEqualSlices(u8, &.{ 128, 0, 0, 128 }, image.pixels);
    try fixture.expectReaped();
}

test "diagram worker deadline kills and reaps a helper that never consumes stdin" {
    var fixture = try Fixture.init(spin);
    defer fixture.deinit();
    // JSON escaping makes this larger than the host pipe's writable capacity.
    @memset(&fixture.job.source, 1);
    fixture.job.len = fixture.job.source.len;
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, worker.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram worker deadline covers a helper that consumes input but produces no output" {
    var fixture = try Fixture.init(drain ++ spin);
    defer fixture.deinit();
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, worker.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram worker rejects endless excess output after the exact declared payload" {
    var fixture = try Fixture.init(drain ++ valid_image ++ "while :; do printf x; done\n");
    defer fixture.deinit();
    var task = fixture.task(2000);
    try std.testing.expectError(error.DiagramLimit, worker.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram worker deadline covers child wait after a valid image and EOF" {
    var fixture = try Fixture.init(drain ++ valid_image ++ close_output ++ spin);
    defer fixture.deinit();
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, worker.renderTask(&task));
    try fixture.expectReaped();
}

test "diagram worker cancellation joins and reaps a live helper before returning" {
    const io = std.testing.io;
    var fixture = try Fixture.init(drain ++ spin);
    defer fixture.deinit();
    var task = fixture.task(8000);
    var future = try io.concurrent(worker.renderTask, .{&task});
    defer if (future.cancel(io)) |value| {
        var image = value;
        image.deinit(std.testing.allocator);
    } else |_| {};
    _ = try fixture.awaitPid();
    try std.testing.expectError(error.Canceled, future.cancel(io));
    try fixture.expectReaped();
}

test "diagram worker preserves explicit helper failure classifications" {
    inline for (.{ .{ "exit 3", error.UnsupportedDiagram }, .{ "exit 4", error.DiagramLimit } }) |case| {
        var fixture = try Fixture.init(drain ++ case[0]);
        defer fixture.deinit();
        var task = fixture.task(2000);
        try std.testing.expectError(case[1], worker.renderTask(&task));
        try fixture.expectReaped();
    }
}

test "diagram worker forcibly terminates a helper that ignores TERM" {
    var fixture = try Fixture.init("trap '' TERM\n" ++ drain ++ valid_image ++ close_output ++ spin);
    defer fixture.deinit();
    var task = fixture.task(1000);
    try std.testing.expectError(error.Timeout, worker.renderTask(&task));
    try fixture.expectReaped();
}

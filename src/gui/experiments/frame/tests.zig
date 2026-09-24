const std = @import("std");
const problem = @import("problem.zig");
const gfx = @import("gfx");
const quad = gfx.Quad;
const Block = @import("Block.zig");
const Frame = @import("Frame.zig");
const Demo = @import("Demo.zig");
const benchmark = @import("benchmark.zig");

test "frame challenge example exposes stable, changed and moving blocks" {
    var demo: Demo = .{};
    try demo.step(.reset);
    try std.testing.expectEqual(@as(usize, 5), demo.cost.quads_copied);
    try demo.step(.repeat);
    try std.testing.expectEqual(@as(usize, 0), demo.cost.quads_copied);
    try demo.step(.edit);
    try std.testing.expectEqual(@as(usize, 3), demo.cost.quads_copied);
    try demo.step(.grow);
    try std.testing.expectEqual(@as(usize, 6), demo.frame.len);
    try std.testing.expectEqual(@as(f32, 8), demo.output[4].x);
    try demo.step(.swap);
    try std.testing.expectEqual(@as(f32, 8), demo.output[0].x);
    for (0..5) |_| {
        try demo.step(.shrink);
    }

    try std.testing.expectEqual(@as(usize, 2), demo.frame.len);
    try demo.step(.repeat);
    try std.testing.expectEqual(@as(usize, 0), demo.cost.quads_copied);
}

test "frame challenge rejects overflow and borrowed output atomically and handles empty input" {
    var values: [2]quad.Quad = @splat(std.mem.zeroes(quad.Quad));
    var output: [2]quad.Quad = @splat(std.mem.zeroes(quad.Quad));
    var frame: Frame = .{ .output = &output };
    var blocks = [_]Block{.{ .id = 1, .revision = 1, .quads = &values }};
    _ = try problem.solve(&blocks, &frame);
    frame.borrowed = true;
    values[0].x = 10;
    blocks[0].revision += 1;
    try std.testing.expectError(error.FrameInFlight, problem.solve(&blocks, &frame));
    try std.testing.expectError(error.FrameInFlight, problem.rebuild(&blocks, &frame));
    try std.testing.expectEqual(@as(f32, 0), output[0].x);
    frame.borrowed = false;
    frame.output = output[0..1];
    const before = frame.previous;
    try std.testing.expectError(error.OutputFull, problem.solve(&blocks, &frame));
    try std.testing.expectEqualDeep(before, frame.previous);
    try std.testing.expectEqual(@as(f32, 0), output[0].x);
    frame.output = &output;
    _ = try problem.solve(&blocks, &frame);
    try std.testing.expectEqual(@as(f32, 10), output[0].x);
    _ = try problem.solve(&.{}, &frame);
    try std.testing.expectEqual(@as(usize, 0), frame.len);
    const too_many: [Frame.max_blocks + 1]Block = @splat(.{ .id = 1, .revision = 1, .quads = &.{} });
    try std.testing.expectError(error.TooManyBlocks, problem.solve(&too_many, &frame));
}

test "frame challenge randomized contents identities lengths and order match independent concatenation" {
    var random = std.Random.DefaultPrng.init(20260923);
    var a: [6]quad.Quad = @splat(std.mem.zeroes(quad.Quad));
    var b: [6]quad.Quad = @splat(std.mem.zeroes(quad.Quad));
    var output: [12]quad.Quad = undefined;
    var expected: [12]quad.Quad = undefined;
    var frame: Frame = .{ .output = &output };
    for (0..2000) |iteration| {
        const rng = random.random();
        // Fill all bytes through floats; equality must cover more than preview ids.
        a[rng.uintLessThan(usize, a.len)].r = rng.float(f32);
        b[rng.uintLessThan(usize, b.len)].x = rng.float(f32);
        var blocks = [_]Block{
            .{ .id = if (iteration % 3 == 0) 3 else 1, .revision = iteration + 1, .quads = a[0..rng.uintLessThan(usize, a.len + 1)] },
            .{ .id = 2, .revision = iteration + 1, .quads = b[0..rng.uintLessThan(usize, b.len + 1)] },
        };
        if (rng.boolean()) {
            std.mem.swap(Block, &blocks[0], &blocks[1]);
        }

        var reference: Frame = .{ .output = &expected };
        _ = try problem.rebuild(&blocks, &reference);
        _ = try problem.solve(&blocks, &frame);
        try std.testing.expectEqual(reference.len, frame.len);
        try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(expected[0..reference.len]), std.mem.sliceAsBytes(output[0..frame.len]));
        const repeated = try problem.solve(&blocks, &frame);
        try std.testing.expectEqual(@as(usize, 0), repeated.quads_copied);
    }
}

test "frame challenge benchmark verifies both functions on every measured input" {
    const results = try benchmark.run(std.testing.allocator, std.testing.io);
    for (results) |result| {
        try std.testing.expect(result.samples > 0);
    }

    try std.testing.expectEqual(@as(usize, 0), results[0].solution_quads);
    try std.testing.expectEqual(results[1].reference_quads / 2, results[1].solution_quads);
    try std.testing.expectEqual(results[2].reference_quads, results[2].solution_quads);
}

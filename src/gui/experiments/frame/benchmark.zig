//! Array composition only. Mutation and byte-for-byte verification are untimed.
const std = @import("std");
const quad = @import("../../render/Quad.zig");
const problem = @import("problem.zig");
const Block = @import("Block.zig");
const Frame = @import("Frame.zig");
const Measurement = @import("Measurement.zig");

pub const names = [_][]const u8{ "Unchanged", "A changes", "A + B change", "A grows/shrinks" };
pub const block_size: usize = 1600;
const warmup = 64;
const sample_count = 2048;

/// Runs identical inputs through both functions, rotating their timing order.
/// Example: `const results = try benchmark.run(gpa, io);`
pub fn run(allocator: std.mem.Allocator, io: std.Io) ![names.len]Measurement {
    const storage = try allocator.alloc(quad.Quad, (block_size + 1) * 6);
    defer allocator.free(storage);
    @memset(storage, std.mem.zeroes(quad.Quad));
    const a = storage[0 .. block_size + 1];
    const b = storage[a.len..][0..a.len];
    const reference_output = storage[a.len * 2 ..][0 .. a.len * 2];
    const solution_output = storage[a.len * 4 ..][0 .. a.len * 2];
    var results: [names.len]Measurement = undefined;
    for (&results, 0..) |*result, scenario| {
        result.* = .{ .name = names[scenario] };
        var reference: Frame = .{ .output = reference_output };
        var solution: Frame = .{ .output = solution_output };
        for (0..warmup + sample_count) |iteration| {
            const changes_a = scenario != 0;
            const changes_b = scenario == 2;
            a[0].x = if (changes_a) @floatFromInt(iteration) else 1;
            b[0].x = if (changes_b) @floatFromInt(iteration) else 2;
            const blocks = [_]Block{
                .{ .id = 1, .revision = if (changes_a) iteration + 1 else 1, .quads = a[0 .. block_size + @intFromBool(scenario == 3 and iteration % 2 == 0)] },
                .{ .id = 2, .revision = if (changes_b) iteration + 1 else 1, .quads = b[0..block_size] },
            };
            for (0..2) |offset| {
                const candidate = (iteration + offset) % 2 != 0;
                const start = std.Io.Clock.awake.now(io).nanoseconds;
                const cost = if (candidate) try problem.solve(&blocks, &solution) else try problem.rebuild(&blocks, &reference);
                const elapsed: u64 = @intCast(@max(0, std.Io.Clock.awake.now(io).nanoseconds - start));
                if (iteration >= warmup) {
                    if (candidate) {
                        result.solution_ns += elapsed;
                        result.solution_quads += cost.quads_copied;
                    } else {
                        result.reference_ns += elapsed;
                        result.reference_quads += cost.quads_copied;
                    }
                }
            }

            if (solution.len != reference.len or !std.mem.eql(u8, std.mem.sliceAsBytes(reference_output[0..reference.len]), std.mem.sliceAsBytes(solution_output[0..solution.len]))) {
                return error.IncorrectSolution;
            }
        }

        result.samples = sample_count;
    }

    return results;
}

/// Prints one small CSV comparison. Example: `run-widget --bench`.
pub fn main(init: std.process.Init) !void {
    const results = try run(init.gpa, init.io);
    var buffer: [2048]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &output.interface;
    try writer.writeAll("case,samples,reference_ns_per_call,solve_ns_per_call,reference_quads_per_call,solve_quads_per_call\n");
    for (results) |result| {
        const count: f64 = @floatFromInt(result.samples);
        try writer.print("{s},{d},{d:.2},{d:.2},{d:.2},{d:.2}\n", .{
            result.name,                                             result.samples,
            @as(f64, @floatFromInt(result.reference_ns)) / count,    @as(f64, @floatFromInt(result.solution_ns)) / count,
            @as(f64, @floatFromInt(result.reference_quads)) / count, @as(f64, @floatFromInt(result.solution_quads)) / count,
        });
    }

    try writer.flush();
}

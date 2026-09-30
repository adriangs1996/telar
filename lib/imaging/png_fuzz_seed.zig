//! Seeds in `std.testing.Smith` input form and the allocation checks the
//! PNG and ICO fuzz roots share. It carries the PNG root's prefix, which the
//! ICO root follows, to stay inside the fuzz roots' names.
//!
//! A seed lists the answers to the Smith calls a fuzz test makes, in order:
//! an integer choice (`value`, `valueRangeAtMost`, `index`, `valueWeighted`)
//! reads eight little-endian bytes, `bytes` reads its length as it is, and
//! `slice` reads a little-endian u32 length before its bytes. A crash the
//! fuzzer saves has the same form.

const std = @import("std");
const BoundedTestAllocator = @import("BoundedTestAllocator.zig");

const FailingAllocator = std.testing.FailingAllocator;
const Weight = std.testing.Smith.Weight;

/// One Smith call a seed answers.
const SeedCall = union(enum) {
    int: u64,
    bytes: []const u8,
};

/// Fails one allocation of a clean decode in about a quarter of the inputs.
pub const failure_weights = [_]Weight{
    .value(
        bool,
        false,
        3,
    ),
    .value(
        bool,
        true,
        1,
    ),
};

/// An integer choice.
/// Example: `seed.int(4)`
pub fn int(value: u64) SeedCall {
    return .{
        .int = value,
    };
}

/// An enum choice, by its value.
/// Example: `seed.tag(ColorType.rgba)`
pub fn tag(value: anytype) SeedCall {
    return int(@intFromEnum(value));
}

/// Bytes a `bytes` call reads, or the data of a `slice` call.
/// Example: `seed.bytes(&samples)`
pub fn bytes(value: []const u8) SeedCall {
    return .{
        .bytes = value,
    };
}

/// The length a `slice` call reads before its data.
/// Example: `seed.sliceLength(telar_ico.len), seed.bytes(telar_ico)`
pub fn sliceLength(comptime len: u32) SeedCall {
    comptime {
        var prefix: [@sizeOf(u32)]u8 = undefined;
        std.mem.writeInt(
            u32,
            &prefix,
            len,
            .little,
        );
        const constant = prefix;
        return bytes(&constant);
    }
}

/// Inputs answered one after another, as one input.
/// Example: `seed.join(&.{ header_input, seed.input(&.{seed.int(1)}) })`
pub fn join(comptime parts: []const []const u8) []const u8 {
    comptime {
        var joined: []const u8 = &.{};
        for (parts) |part| {
            joined = joined ++ part;
        }

        const constant = joined[0..joined.len].*;
        return &constant;
    }
}

/// The Smith input that answers `calls`.
/// Example: `const corpus_entry = seed.input(&.{ seed.tag(PngCase.generated) });`
pub fn input(comptime calls: []const SeedCall) []const u8 {
    comptime {
        @setEvalBranchQuota(calls.len * 16);
        var encoded: []const u8 = &.{};
        for (calls) |call| {
            switch (call) {
                .int => |value| {
                    var little: [@sizeOf(u64)]u8 = undefined;
                    std.mem.writeInt(
                        u64,
                        &little,
                        value,
                        .little,
                    );
                    encoded = encoded ++ little;
                },
                .bytes => |value| encoded = encoded ++ value,
            }
        }

        const constant = encoded[0..encoded.len].*;
        return &constant;
    }
}

/// Every byte `failing` handed out came back, in as many frees.
/// Example: `try seed.expectReleased(&failing);`
pub fn expectReleased(failing: *const FailingAllocator) !void {
    try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    try std.testing.expectEqual(failing.allocations, failing.deallocations);
}

/// No request reached the hard limit of `bounded`, and nothing is live.
/// Example: `try seed.expectWithinBudget(&bounded);`
pub fn expectWithinBudget(bounded: *const BoundedTestAllocator) !void {
    try std.testing.expectEqual(0, bounded.refusals);
    try std.testing.expectEqual(0, bounded.live_bytes);
}

test "seed calls encode as the Smith input that replays them" {
    const encoded = comptime join(&.{
        input(&.{ int(7), bytes("ab") }),
        input(&.{ sliceLength(1), bytes("c") }),
    });

    var smith: std.testing.Smith = .{
        .in = encoded,
    };
    const choice = smith.valueRangeAtMost(
        u32,
        0,
        9,
    );
    try std.testing.expectEqual(7, choice);

    var two: [2]u8 = undefined;
    smith.bytes(&two);
    try std.testing.expectEqualStrings("ab", &two);

    var one: [4]u8 = undefined;
    try std.testing.expectEqualStrings("c", one[0..smith.slice(&one)]);
}

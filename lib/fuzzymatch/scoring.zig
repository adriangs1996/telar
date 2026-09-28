//! fzy's scoring over bytes, in integers: the best alignment of a needle as
//! a case-insensitive subsequence of a haystack, rewarding matches right
//! after a separator or at a lowercase-to-uppercase step, and consecutive
//! runs, and charging every skipped byte. Paths rank by their file name
//! because a match after the last `/` collects the separator bonus.

const std = @import("std");
const Matrix = @import("Matrix.zig");

pub const max_needle_bytes = Matrix.max_needle_bytes;
pub const max_haystack_bytes = Matrix.max_haystack_bytes;

/// An exact case-insensitive match of the whole haystack.
pub const max_score: i32 = std.math.maxInt(i32) / 2;
/// A haystack too long to align still matches, below every aligned one.
pub const overlong_score: i32 = std.math.minInt(i32) / 2;

/// A cell no alignment reaches.
const unreachable_score: i32 = std.math.minInt(i32);
const consecutive_score: i32 = 1000;

/// What a match earns from the byte before it.
const Bonus = enum(i32) {
    none = 0,
    dot = 600,
    capital = 700,
    word = 800,
    slash = 900,
};

/// What every skipped haystack byte costs, by where it sits: before the
/// first match, between matches, or after the last needle byte matched.
const leading_gap: i32 = -5;
const inner_gap: i32 = -10;
const trailing_gap: i32 = -5;

const Shape = enum {
    empty,
    exact,
    overlong,
    aligned,
};

/// One needle byte's pass over the haystack, reading the previous row.
const Row = struct {
    index: usize,
    last: bool,
    byte: u8,
    previous_ending: []const i32,
    previous_best: []const i32,
    ending: []i32,
    best: []i32,
};

/// Null when `needle` is not a case-insensitive subsequence of `haystack`
/// or is longer than `max_needle_bytes`. Higher is better; an empty needle
/// scores 0 for every haystack.
///
/// ```zig
/// const rank = scoring.score("src/types/License.ts", "licens.ts") orelse return;
/// ```
pub fn score(haystack: []const u8, needle: []const u8) ?i32 {
    switch (shapeOf(haystack, needle) orelse return null) {
        .empty => return 0,
        .exact => return max_score,
        .overlong => return overlong_score,
        .aligned => {},
    }

    var bonuses: [max_haystack_bytes]i32 = undefined;
    fillBonuses(haystack, &bonuses);

    var ending: [2][max_haystack_bytes]i32 = undefined;
    var best: [2][max_haystack_bytes]i32 = undefined;
    for (needle, 0..) |byte, index| {
        const current = index % 2;
        const previous = 1 - current;
        fillRow(
            .{
                .index = index,
                .last = index + 1 == needle.len,
                .byte = byte,
                .previous_ending = ending[previous][0..haystack.len],
                .previous_best = best[previous][0..haystack.len],
                .ending = ending[current][0..haystack.len],
                .best = best[current][0..haystack.len],
            },
            haystack,
            bonuses[0..haystack.len],
        );
    }

    return best[(needle.len - 1) % 2][haystack.len - 1];
}

/// Scores like `score` and writes the haystack offset of every needle byte
/// into `positions`, which holds at least `needle.len` entries. The offsets
/// belong to the alignment that produced the score, so a renderer
/// highlights exactly what ranked the row.
///
/// ```zig
/// var positions: [scoring.max_needle_bytes]u16 = undefined;
/// const rank = scoring.match(matrix, path, query, &positions) orelse return;
/// ```
pub fn match(matrix: *Matrix, haystack: []const u8, needle: []const u8, positions: []u16) ?i32 {
    std.debug.assert(positions.len >= needle.len);

    switch (shapeOf(haystack, needle) orelse return null) {
        .empty => return 0,
        .exact => {
            for (positions[0..needle.len], 0..) |*position, index| {
                position.* = @intCast(index);
            }

            return max_score;
        },
        .overlong => {
            firstPositions(
                haystack,
                needle,
                positions,
            );
            return overlong_score;
        },
        .aligned => {},
    }

    var bonuses: [max_haystack_bytes]i32 = undefined;
    fillBonuses(haystack, &bonuses);

    for (needle, 0..) |byte, index| {
        const previous = if (index == 0) 0 else index - 1;
        fillRow(
            .{
                .index = index,
                .last = index + 1 == needle.len,
                .byte = byte,
                .previous_ending = matrix.ending[previous][0..haystack.len],
                .previous_best = matrix.best[previous][0..haystack.len],
                .ending = matrix.ending[index][0..haystack.len],
                .best = matrix.best[index][0..haystack.len],
            },
            haystack,
            bonuses[0..haystack.len],
        );
    }

    walkBack(
        matrix,
        .{
            .needle_len = needle.len,
            .haystack_len = haystack.len,
        },
        positions,
    );
    return matrix.best[needle.len - 1][haystack.len - 1];
}

fn shapeOf(haystack: []const u8, needle: []const u8) ?Shape {
    if (needle.len == 0) {
        return .empty;
    }

    if (needle.len > max_needle_bytes or needle.len > haystack.len or !isSubsequence(haystack, needle)) {
        return null;
    }

    if (haystack.len > max_haystack_bytes) {
        return .overlong;
    }

    if (needle.len == haystack.len) {
        return .exact;
    }

    return .aligned;
}

fn isSubsequence(haystack: []const u8, needle: []const u8) bool {
    var index: usize = 0;
    for (haystack) |byte| {
        if (std.ascii.toLower(byte) == std.ascii.toLower(needle[index])) {
            index += 1;
            if (index == needle.len) {
                return true;
            }
        }
    }

    return false;
}

fn firstPositions(haystack: []const u8, needle: []const u8, positions: []u16) void {
    var index: usize = 0;
    for (haystack, 0..) |byte, offset| {
        if (index == needle.len) {
            return;
        }

        if (std.ascii.toLower(byte) == std.ascii.toLower(needle[index])) {
            positions[index] = @intCast(@min(offset, std.math.maxInt(u16)));
            index += 1;
        }
    }
}

fn fillBonuses(haystack: []const u8, bonuses: []i32) void {
    var previous: u8 = '/';
    for (haystack, 0..) |byte, index| {
        bonuses[index] = @intFromEnum(bonusAfter(previous, byte));
        previous = byte;
    }
}

fn bonusAfter(previous: u8, byte: u8) Bonus {
    if (!std.ascii.isAlphanumeric(byte)) {
        return .none;
    }

    return switch (previous) {
        '/' => .slash,
        '-', '_', ' ' => .word,
        '.' => .dot,
        else => if (std.ascii.isLower(previous) and std.ascii.isUpper(byte)) .capital else .none,
    };
}

fn fillRow(row: Row, haystack: []const u8, bonuses: []const i32) void {
    const gap = if (row.last) trailing_gap else inner_gap;
    const wanted = std.ascii.toLower(row.byte);
    var running: i32 = unreachable_score;
    for (haystack, 0..) |byte, column| {
        if (std.ascii.toLower(byte) != wanted) {
            row.ending[column] = unreachable_score;
            running = plus(running, gap);
            row.best[column] = running;
            continue;
        }

        var cell: i32 = unreachable_score;
        if (row.index == 0) {
            cell = @as(i32, @intCast(column)) * leading_gap + bonuses[column];
        } else if (column > 0) {
            cell = @max(plus(row.previous_best[column - 1], bonuses[column]), plus(row.previous_ending[column - 1], consecutive_score));
        }

        row.ending[column] = cell;
        running = @max(cell, plus(running, gap));
        row.best[column] = running;
    }
}

/// Adds to a reachable score; an unreachable cell stays unreachable.
fn plus(value: i32, delta: i32) i32 {
    if (value == unreachable_score) {
        return unreachable_score;
    }

    return value + delta;
}

const Extent = struct {
    needle_len: usize,
    haystack_len: usize,
};

/// Walks from the last needle byte to the first, taking for each the
/// rightmost column that belongs to the best alignment. A cell reached by
/// a consecutive step forces the previous byte into the column before it.
fn walkBack(matrix: *const Matrix, extent: Extent, positions: []u16) void {
    var required = false;
    var column: usize = extent.haystack_len;
    var index: usize = extent.needle_len;
    while (index > 0) {
        index -= 1;
        while (column > 0) {
            column -= 1;
            const cell = matrix.ending[index][column];
            if (cell == unreachable_score or !(required or cell == matrix.best[index][column])) {
                continue;
            }

            required = index > 0 and column > 0 and cell == plus(matrix.ending[index - 1][column - 1], consecutive_score);
            positions[index] = @intCast(column);
            break;
        }
    }
}

test "the file name outranks a match spread across directories" {
    const license = score("apps/license-lookup-app/src/types/License.ts", "licens.ts").?;
    const app = score("apps/license-lookup-app/src/app.d.ts", "licens.ts").?;
    try std.testing.expect(license > app);
}

test "separators, capitals and consecutive runs earn more than scattered bytes" {
    try std.testing.expect(score("FooBarBaz", "fbb").? > score("foobarbaz", "fbb").?);
    try std.testing.expect(score("zig build test", "zbt").? > score("zigbuildtest", "zbt").?);
    try std.testing.expect(score("app.ts", "app").? > score("a-p-p.ts", "app").?);
    try std.testing.expect(score("src/app.ts", "app").? > score("sr/xapp.ts", "app").?);
}

test "empty, exact, missing, overlong and oversized needles" {
    try std.testing.expectEqual(@as(?i32, 0), score("anything", ""));
    try std.testing.expectEqual(@as(?i32, max_score), score("Telar", "telar"));
    try std.testing.expectEqual(@as(?i32, null), score("telar", "xyz"));
    try std.testing.expectEqual(@as(?i32, null), score("ab", "abc"));

    const long = [_]u8{'a'} ** (max_haystack_bytes + 1);
    try std.testing.expectEqual(@as(?i32, overlong_score), score(&long, "aa"));

    const needle = [_]u8{'a'} ** (max_needle_bytes + 1);
    try std.testing.expectEqual(@as(?i32, null), score(&long, &needle));
}

test "positions follow the alignment that produced the score" {
    const matrix = try Matrix.create(std.testing.allocator);
    defer std.testing.allocator.destroy(matrix);

    const path = "apps/license-lookup-app/src/types/License.ts";
    var positions: [max_needle_bytes]u16 = undefined;
    const rank = match(
        matrix,
        path,
        "licens.ts",
        &positions,
    ).?;
    try std.testing.expectEqual(score(path, "licens.ts").?, rank);

    const base: u16 = @intCast(std.mem.lastIndexOfScalar(
        u8,
        path,
        '/',
    ).? + 1);
    const expected = [_]u16{ base, base + 1, base + 2, base + 3, base + 4, base + 5, base + 7, base + 8, base + 9 };
    try std.testing.expectEqualSlices(
        u16,
        &expected,
        positions[0..expected.len],
    );

    try std.testing.expectEqual(@as(?i32, max_score), match(
        matrix,
        "Telar",
        "telar",
        &positions,
    ));
    try std.testing.expectEqualSlices(
        u16,
        &.{ 0, 1, 2, 3, 4 },
        positions[0..5],
    );
    try std.testing.expectEqual(@as(?i32, null), match(
        matrix,
        "telar",
        "xyz",
        &positions,
    ));
}

test "a consecutive run keeps its bytes together when walking back" {
    const matrix = try Matrix.create(std.testing.allocator);
    defer std.testing.allocator.destroy(matrix);

    var positions: [max_needle_bytes]u16 = undefined;
    _ = match(
        matrix,
        "a/ab/abc",
        "abc",
        &positions,
    ).?;
    try std.testing.expectEqualSlices(
        u16,
        &.{ 5, 6, 7 },
        positions[0..3],
    );
}

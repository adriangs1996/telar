//! Exact-host and wildcard allowlist for TLS interception.

const core = @import("telar-core");
const std = @import("std");

pub fn deduplicate(values: [][]const u8, comptime compareFn: fn ([]const u8, []const u8) std.math.Order) u16 {
    var unique_count: usize = 0;
    for (values) |value| {
        if (unique_count != 0 and compareFn(values[unique_count - 1], value) == .eq) {
            continue;
        }

        values[unique_count] = value;
        unique_count += 1;
    }

    return @intCast(unique_count);
}

pub fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return core.orderHostname(left, right) == .lt;
}

pub fn compare(target: []const u8, candidate: []const u8) std.math.Order {
    return core.orderHostname(target, candidate);
}

pub fn suffixLessThan(_: void, left: []const u8, right: []const u8) bool {
    return orderReversedLabels(left, right) == .lt;
}

pub fn compareSuffix(target: []const u8, candidate: []const u8) std.math.Order {
    return orderReversedLabels(target, candidate);
}

fn orderReversedLabels(left: []const u8, right: []const u8) std.math.Order {
    var left_end = left.len;
    var right_end = right.len;
    while (left_end != 0 and right_end != 0) {
        const left_start = if (std.mem.lastIndexOfScalar(u8, left[0..left_end], '.')) |index| index + 1 else 0;
        const right_start = if (std.mem.lastIndexOfScalar(u8, right[0..right_end], '.')) |index| index + 1 else 0;
        const order = core.orderHostname(left[left_start..left_end], right[right_start..right_end]);
        if (order != .eq) {
            return order;
        }

        left_end = if (left_start == 0) 0 else left_start - 1;
        right_end = if (right_start == 0) 0 else right_start - 1;
    }

    return std.math.order(left_end, right_end);
}

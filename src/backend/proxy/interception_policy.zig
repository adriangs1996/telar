//! Exact-host and wildcard allowlist for TLS interception.

const std = @import("std");
const orderHostname_module = @import("telar-core").orderHostname;
const Policy = @import("Policy.zig");
const max_intercept_hosts_module = @import("telar-core").max_intercept_hosts;
const max_hostname_bytes_module = @import("telar-core").max_hostname_bytes;

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
    return orderHostname_module(left, right) == .lt;
}

pub fn compare(target: []const u8, candidate: []const u8) std.math.Order {
    return orderHostname_module(target, candidate);
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
        const order = orderHostname_module(left[left_start..left_end], right[right_start..right_end]);
        if (order != .eq) {
            return order;
        }

        left_end = if (left_start == 0) 0 else left_start - 1;
        right_end = if (right_start == 0) 0 else right_start - 1;
    }

    return std.math.order(left_end, right_end);
}

test "configured hosts form one canonical interception allowlist" {
    const policy = try Policy.init(&.{
        "api.openai.com",
        "API.OPENAI.COM",
        "api.anthropic.com",
    });

    try std.testing.expectEqual(@as(u16, 2), policy.exact_count);
    try std.testing.expect(policy.contains("API.ANTHROPIC.COM"));
    try std.testing.expect(policy.contains("api.openai.com"));
}

test "suffix and global wildcards authorize only their intended hosts" {
    const suffixes = try Policy.init(&.{ "*.Example.com", "*.api.example.com", "*.EXAMPLE.com" });
    const global = try Policy.init(&.{"*"});

    try std.testing.expectEqual(@as(u16, 2), suffixes.suffix_count);
    try std.testing.expect(suffixes.contains("one.example.com"));
    try std.testing.expect(suffixes.contains("deep.one.EXAMPLE.COM"));
    try std.testing.expect(!suffixes.contains("example.com"));
    try std.testing.expect(!suffixes.contains("badexample.com"));
    try std.testing.expect(!suffixes.contains("example.com.evil.test"));
    try std.testing.expect(global.contains("anything.invalid"));
    try std.testing.expect(!global.contains(""));
}

test "empty policy and partial host matches never authorize interception" {
    const empty = try Policy.init(&.{});
    const configured = try Policy.init(&.{"api.openai.com"});

    try std.testing.expect(!empty.contains("api.openai.com"));
    try std.testing.expect(!configured.contains("openai.com"));
    try std.testing.expect(!configured.contains("evil-api.openai.com"));
    try std.testing.expect(!configured.contains("api.openai.com.evil.example"));
}

test "configured hosts respect count and hostname bounds" {
    var too_many: [max_intercept_hosts_module + 1][]const u8 = @splat("example.com");

    try std.testing.expectError(error.TooManyProxyInterceptHosts, Policy.init(&too_many));
    try std.testing.expectError(error.InvalidProxyInterceptHost, Policy.init(&.{""}));
    try std.testing.expectError(error.InvalidProxyInterceptHost, Policy.init(&.{"*example.com"}));
    try std.testing.expectError(error.InvalidProxyInterceptHost, Policy.init(&.{"api.*.example.com"}));

    const oversized = "x" ** (max_hostname_bytes_module + 1);
    try std.testing.expectError(error.InvalidProxyInterceptHost, Policy.init(&.{oversized}));
}

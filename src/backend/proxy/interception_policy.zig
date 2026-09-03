//! Exact-host and wildcard allowlist for TLS interception.

const std = @import("std");
const core = @import("telar-core");

pub const max_configured_hosts = core.proxy.max_intercept_hosts;

pub const Policy = struct {
    exact_storage: [max_configured_hosts][]const u8 = undefined,
    exact_count: u16 = 0,
    suffix_storage: [max_configured_hosts][]const u8 = undefined,
    suffix_count: u16 = 0,
    intercept_all: bool = false,

    /// Builds an immutable, case-insensitive host allowlist. Strings are
    /// borrowed and must outlive the policy. `*.example.com` covers proper
    /// subdomains and `*` covers every authenticated CONNECT hostname.
    ///
    /// ```zig
    /// const policy = try Policy.init(&.{"api.openai.com"});
    /// ```
    pub fn init(configured: []const []const u8) !Policy {
        if (configured.len > max_configured_hosts) {
            return error.TooManyProxyInterceptHosts;
        }

        var policy: Policy = .{};
        for (configured) |host| {
            if (host.len == 0 or host.len > core.proxy.max_hostname_bytes) {
                return error.InvalidProxyInterceptHost;
            }

            if (std.mem.eql(u8, host, "*")) {
                policy.intercept_all = true;
            } else if (std.mem.startsWith(u8, host, "*.")) {
                if (host.len == 2 or std.mem.indexOfScalar(u8, host[2..], '*') != null) {
                    return error.InvalidProxyInterceptHost;
                }

                policy.appendSuffix(host[2..]);
            } else {
                if (std.mem.indexOfScalar(u8, host, '*') != null) {
                    return error.InvalidProxyInterceptHost;
                }

                policy.appendExact(host);
            }
        }

        std.mem.sort([]const u8, policy.exact_storage[0..policy.exact_count], {}, lessThan);
        std.mem.sort([]const u8, policy.suffix_storage[0..policy.suffix_count], {}, suffixLessThan);
        policy.exact_count = deduplicate(policy.exact_storage[0..policy.exact_count], compare);
        policy.suffix_count = deduplicate(policy.suffix_storage[0..policy.suffix_count], compareSuffix);
        return policy;
    }

    /// Reports whether the complete hostname may be intercepted. A suffix rule
    /// requires at least one label before its configured suffix.
    ///
    /// ```zig
    /// if (policy.contains("api.openai.com")) {
    ///     interceptTls();
    /// }
    /// ```
    pub fn contains(policy: *const Policy, host: []const u8) bool {
        if (host.len == 0) {
            return false;
        }

        if (policy.intercept_all) {
            return true;
        }
        if (std.sort.binarySearch([]const u8, policy.exact_storage[0..policy.exact_count], host, compare) != null) {
            return true;
        }

        var offset = std.mem.indexOfScalar(u8, host, '.') orelse return false;
        while (offset + 1 < host.len) {
            const suffix = host[offset + 1 ..];
            if (std.sort.binarySearch([]const u8, policy.suffix_storage[0..policy.suffix_count], suffix, compareSuffix) != null) {
                return true;
            }

            const next = std.mem.indexOfScalar(u8, suffix, '.') orelse return false;
            offset += next + 1;
        }

        return false;
    }

    fn appendExact(policy: *Policy, host: []const u8) void {
        policy.exact_storage[policy.exact_count] = host;
        policy.exact_count += 1;
    }

    fn appendSuffix(policy: *Policy, host: []const u8) void {
        policy.suffix_storage[policy.suffix_count] = host;
        policy.suffix_count += 1;
    }
};

fn deduplicate(values: [][]const u8, comptime compareFn: fn ([]const u8, []const u8) std.math.Order) u16 {
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

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return core.proxy.orderHostname(left, right) == .lt;
}

fn compare(target: []const u8, candidate: []const u8) std.math.Order {
    return core.proxy.orderHostname(target, candidate);
}

fn suffixLessThan(_: void, left: []const u8, right: []const u8) bool {
    return orderReversedLabels(left, right) == .lt;
}

fn compareSuffix(target: []const u8, candidate: []const u8) std.math.Order {
    return orderReversedLabels(target, candidate);
}

fn orderReversedLabels(left: []const u8, right: []const u8) std.math.Order {
    var left_end = left.len;
    var right_end = right.len;
    while (left_end != 0 and right_end != 0) {
        const left_start = if (std.mem.lastIndexOfScalar(u8, left[0..left_end], '.')) |index| index + 1 else 0;
        const right_start = if (std.mem.lastIndexOfScalar(u8, right[0..right_end], '.')) |index| index + 1 else 0;
        const order = core.proxy.orderHostname(left[left_start..left_end], right[right_start..right_end]);
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
    var too_many: [max_configured_hosts + 1][]const u8 = @splat("example.com");

    try std.testing.expectError(error.TooManyProxyInterceptHosts, Policy.init(&too_many));
    try std.testing.expectError(error.InvalidProxyInterceptHost, Policy.init(&.{""}));
    try std.testing.expectError(error.InvalidProxyInterceptHost, Policy.init(&.{"*example.com"}));
    try std.testing.expectError(error.InvalidProxyInterceptHost, Policy.init(&.{"api.*.example.com"}));

    const oversized = "x" ** (core.proxy.max_hostname_bytes + 1);
    try std.testing.expectError(error.InvalidProxyInterceptHost, Policy.init(&.{oversized}));
}

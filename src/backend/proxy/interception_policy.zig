//! Exact-host allowlist for TLS interception.

const std = @import("std");
const core = @import("telar-core");

pub const max_configured_hosts = core.proxy.max_intercept_hosts;

pub const Policy = struct {
    storage: [max_configured_hosts][]const u8 = undefined,
    count: u16 = 0,

    /// Builds an immutable, case-insensitive exact-host allowlist. Strings are
    /// borrowed and must outlive the policy. An empty policy intercepts no host.
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

            policy.append(host);
        }

        std.mem.sort([]const u8, policy.storage[0..policy.count], {}, lessThan);
        policy.deduplicate();
        return policy;
    }

    /// Reports whether the complete hostname may be intercepted. Matching is
    /// ASCII case-insensitive and never matches suffixes.
    ///
    /// ```zig
    /// if (policy.contains("api.openai.com")) {
    ///     interceptTls();
    /// }
    /// ```
    pub fn contains(policy: *const Policy, host: []const u8) bool {
        return std.sort.binarySearch([]const u8, policy.storage[0..policy.count], host, compare) != null;
    }

    fn append(policy: *Policy, host: []const u8) void {
        policy.storage[policy.count] = host;
        policy.count += 1;
    }

    fn deduplicate(policy: *Policy) void {
        var unique_count: usize = 0;

        for (policy.storage[0..policy.count]) |host| {
            if (unique_count != 0 and core.proxy.orderHostname(policy.storage[unique_count - 1], host) == .eq) {
                continue;
            }

            policy.storage[unique_count] = host;
            unique_count += 1;
        }

        policy.count = @intCast(unique_count);
    }
};

fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return core.proxy.orderHostname(left, right) == .lt;
}

fn compare(target: []const u8, candidate: []const u8) std.math.Order {
    return core.proxy.orderHostname(target, candidate);
}

test "configured hosts form one canonical interception allowlist" {
    const policy = try Policy.init(&.{
        "api.openai.com",
        "API.OPENAI.COM",
        "api.anthropic.com",
    });

    try std.testing.expectEqual(@as(u16, 2), policy.count);
    try std.testing.expect(policy.contains("API.ANTHROPIC.COM"));
    try std.testing.expect(policy.contains("api.openai.com"));
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

    const oversized = "x" ** (core.proxy.max_hostname_bytes + 1);
    try std.testing.expectError(error.InvalidProxyInterceptHost, Policy.init(&.{oversized}));
}

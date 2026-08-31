//! Exact-host policy for TLS tunnels that must bypass interception.

const std = @import("std");
const core = @import("telar-core");

pub const max_configured_hosts = core.proxy.max_passthrough_hosts;

const default_hosts = [_][]const u8{
    "api.github.com",
    "ab.chatgpt.com",
};
const capacity = max_configured_hosts + default_hosts.len;

pub const Policy = struct {
    storage: [capacity][]const u8 = undefined,
    count: u16 = 0,

    /// Builds an immutable, case-insensitive exact-host policy. Configured
    /// strings are borrowed and must outlive the policy.
    ///
    /// ```zig
    /// const policy = try Policy.init(&.{"updates.example.com"});
    /// ```
    pub fn init(configured: []const []const u8) !Policy {
        if (configured.len > max_configured_hosts) {
            return error.TooManyProxyPassthroughHosts;
        }

        var policy: Policy = .{};
        for (default_hosts) |host| {
            policy.append(host);
        }

        for (configured) |host| {
            if (host.len == 0 or host.len > core.proxy.max_hostname_bytes) {
                return error.InvalidProxyPassthroughHost;
            }

            policy.append(host);
        }

        std.mem.sort([]const u8, policy.storage[0..policy.count], {}, lessThan);
        policy.deduplicate();
        return policy;
    }

    /// Reports whether the complete hostname belongs to the bypass policy.
    /// Matching is ASCII case-insensitive and never matches suffixes.
    ///
    /// ```zig
    /// if (policy.contains("api.github.com")) {
    ///     relayWithoutInterception();
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

test "defaults and configured hosts form one deduplicated policy" {
    const policy = try Policy.init(&.{
        "updates.example.com",
        "API.GITHUB.COM",
    });

    try std.testing.expectEqual(@as(u16, 3), policy.count);
    try std.testing.expect(policy.contains("api.github.com"));
    try std.testing.expect(policy.contains("AB.CHATGPT.COM"));
    try std.testing.expect(policy.contains("UPDATES.EXAMPLE.COM"));
}

test "matching requires the complete hostname" {
    const policy = try Policy.init(&.{});

    try std.testing.expect(!policy.contains("github.com"));
    try std.testing.expect(!policy.contains("evil-api.github.com"));
    try std.testing.expect(!policy.contains("api.github.com.evil.example"));
}

test "configured hosts respect count and hostname bounds" {
    var too_many: [max_configured_hosts + 1][]const u8 = @splat("example.com");
    try std.testing.expectError(error.TooManyProxyPassthroughHosts, Policy.init(&too_many));
    try std.testing.expectError(error.InvalidProxyPassthroughHost, Policy.init(&.{""}));

    const oversized = "x" ** (core.proxy.max_hostname_bytes + 1);
    try std.testing.expectError(error.InvalidProxyPassthroughHost, Policy.init(&.{oversized}));
}

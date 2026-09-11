const Policy = @This();
const source_namespace = @import("interception_policy.zig");
const core = @import("telar-core");
const std = @import("std");
exact_storage: [source_namespace.max_configured_hosts][]const u8 = undefined,
exact_count: u16 = 0,
suffix_storage: [source_namespace.max_configured_hosts][]const u8 = undefined,
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
    if (configured.len > source_namespace.max_configured_hosts) {
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

    std.mem.sort([]const u8, policy.exact_storage[0..policy.exact_count], {}, source_namespace.lessThan);
    std.mem.sort([]const u8, policy.suffix_storage[0..policy.suffix_count], {}, source_namespace.suffixLessThan);
    policy.exact_count = source_namespace.deduplicate(policy.exact_storage[0..policy.exact_count], source_namespace.compare);
    policy.suffix_count = source_namespace.deduplicate(policy.suffix_storage[0..policy.suffix_count], source_namespace.compareSuffix);
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
    if (std.sort.binarySearch([]const u8, policy.exact_storage[0..policy.exact_count], host, source_namespace.compare) != null) {
        return true;
    }

    var offset = std.mem.indexOfScalar(u8, host, '.') orelse return false;
    while (offset + 1 < host.len) {
        const suffix = host[offset + 1 ..];
        if (std.sort.binarySearch([]const u8, policy.suffix_storage[0..policy.suffix_count], suffix, source_namespace.compareSuffix) != null) {
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

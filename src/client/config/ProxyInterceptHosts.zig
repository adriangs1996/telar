const max_intercept_bytes = @import("telar-core").max_intercept_bytes;
const max_intercept_hosts = @import("telar-core").max_intercept_hosts;
const Reference = @import("Reference.zig");
const std = @import("std");
const max_hostname_bytes = @import("telar-core").max_hostname_bytes;
const orderHostname_module = @import("telar-core").orderHostname;
const ProxyInterceptHosts = @This();

bytes: [max_intercept_bytes]u8 = undefined,
byte_len: u16 = 0,
references: [max_intercept_hosts]Reference = undefined,
count: u16 = 0,

comptime {
    std.debug.assert(max_intercept_bytes <= std.math.maxInt(u16));
}

/// Appends one canonical hostname within the fixed count and byte budgets.
///
/// ```zig
/// try hosts.append("api.openai.com");
/// ```
pub fn append(hosts: *ProxyInterceptHosts, host: []const u8) !void {
    if (hosts.count == max_intercept_hosts) {
        return error.TooManyProxyInterceptHosts;
    }

    if (host.len == 0 or host.len > max_hostname_bytes) {
        return error.InvalidProxyInterceptHost;
    }

    const end = @as(usize, hosts.byte_len) + host.len;
    if (end > hosts.bytes.len) {
        return error.ProxyInterceptHostsTooLarge;
    }

    const offset = hosts.byte_len;
    for (host, hosts.bytes[offset..end]) |byte, *destination| {
        destination.* = std.ascii.toLower(byte);
    }

    hosts.references[hosts.count] = .{
        .offset = offset,
        .len = @intCast(host.len),
    };
    hosts.byte_len = @intCast(end);
    hosts.count += 1;
}

/// Sorts the hostnames for binary search and removes case-insensitive
/// duplicates.
///
/// ```zig
/// hosts.sortAndDeduplicate();
/// ```
pub fn sortAndDeduplicate(hosts: *ProxyInterceptHosts) void {
    std.mem.sort(
        Reference,
        hosts.references[0..hosts.count],
        hosts,
        struct {
            fn lessThan(context: *const ProxyInterceptHosts, left: Reference, right: Reference) bool {
                return orderHostname_module(
                    context.value(left),
                    context.value(right),
                ) == .lt;
            }
        }.lessThan,
    );

    var unique_count: usize = 0;
    for (hosts.references[0..hosts.count]) |reference| {
        if (unique_count != 0 and orderHostname_module(
            hosts.value(hosts.references[unique_count - 1]),
            hosts.value(reference),
        ) == .eq) {
            continue;
        }

        hosts.references[unique_count] = reference;
        unique_count += 1;
    }

    hosts.count = @intCast(unique_count);
}

/// Materializes borrowed slices for the runtime bootstrap. The returned
/// strings remain owned by this configuration snapshot.
///
/// ```zig
/// const configured = hosts.slices(&storage);
/// ```
pub fn slices(hosts: *const ProxyInterceptHosts, storage: *[max_intercept_hosts][]const u8) []const []const u8 {
    for (hosts.references[0..hosts.count], 0..) |reference, index| {
        storage[index] = hosts.value(reference);
    }

    return storage[0..hosts.count];
}

fn value(hosts: *const ProxyInterceptHosts, reference: Reference) []const u8 {
    return hosts.bytes[reference.offset..][0..reference.len];
}

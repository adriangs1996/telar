const core = @import("telar-core");
const Reference = @import("Reference.zig");
const std = @import("std");
const ProxyInterceptHosts = @This();

bytes: [core.max_intercept_bytes]u8 = undefined,
byte_len: u16 = 0,
references: [core.max_intercept_hosts]Reference = undefined,
count: u16 = 0,

comptime {
    std.debug.assert(core.max_intercept_bytes <= std.math.maxInt(u16));
}

/// Appends one canonical hostname within the fixed count and byte budgets.
///
/// ```zig
/// try hosts.append("api.openai.com");
/// ```
pub fn append(self: *ProxyInterceptHosts, host: []const u8) !void {
    if (self.count == core.max_intercept_hosts) {
        return error.TooManyProxyInterceptHosts;
    }

    if (host.len == 0 or host.len > core.max_hostname_bytes) {
        return error.InvalidProxyInterceptHost;
    }

    const end = @as(usize, self.byte_len) + host.len;
    if (end > self.bytes.len) {
        return error.ProxyInterceptHostsTooLarge;
    }

    const offset = self.byte_len;
    for (host, self.bytes[offset..end]) |byte, *destination| {
        destination.* = std.ascii.toLower(byte);
    }

    self.references[self.count] = .{
        .offset = offset,
        .len = @intCast(host.len),
    };
    self.byte_len = @intCast(end);
    self.count += 1;
}

/// Sorts the hostnames for binary search and removes case-insensitive
/// duplicates.
///
/// ```zig
/// hosts.sortAndDeduplicate();
/// ```
pub fn sortAndDeduplicate(self: *ProxyInterceptHosts) void {
    std.mem.sort(
        Reference,
        self.references[0..self.count],
        self,
        struct {
            fn lessThan(context: *const ProxyInterceptHosts, left: Reference, right: Reference) bool {
                return core.orderHostname(
                    context.value(left),
                    context.value(right),
                ) == .lt;
            }
        }.lessThan,
    );

    var unique_count: usize = 0;
    for (self.references[0..self.count]) |reference| {
        if (unique_count != 0 and core.orderHostname(
            self.value(self.references[unique_count - 1]),
            self.value(reference),
        ) == .eq) {
            continue;
        }

        self.references[unique_count] = reference;
        unique_count += 1;
    }

    self.count = @intCast(unique_count);
}

/// Materializes borrowed slices for the runtime bootstrap. The returned
/// strings remain owned by this configuration snapshot.
///
/// ```zig
/// const configured = hosts.slices(&storage);
/// ```
pub fn slices(self: *const ProxyInterceptHosts, storage: *[core.max_intercept_hosts][]const u8) []const []const u8 {
    for (self.references[0..self.count], 0..) |reference, index| {
        storage[index] = self.value(reference);
    }

    return storage[0..self.count];
}

fn value(self: *const ProxyInterceptHosts, reference: Reference) []const u8 {
    return self.bytes[reference.offset..][0..reference.len];
}

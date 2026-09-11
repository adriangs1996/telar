const TrustStore = @This();
const source_namespace = @import("plugin.zig");
const StoredGrant = @import("StoredGrant.zig");
const std = @import("std");
const Manifest = @import("PluginManifest.zig");
const GrantUpdate = @import("GrantUpdate.zig");
const Grant = @import("Grant.zig");
entries: [source_namespace.max_grants]StoredGrant = undefined,
count: u8 = 0,

pub fn parse(gpa: std.mem.Allocator, source: []const u8) !TrustStore {
    const WireGrant = struct {
        plugin: []const u8,
        digest: []const u8,
        capabilities: []const []const u8,
    };
    const WireStore = struct { version: u16, grants: []const WireGrant };
    const parsed = try std.json.parseFromSlice(WireStore, gpa, source, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    if (parsed.value.version != 1) {
        return error.IncompatibleTrustStore;
    }
    if (parsed.value.grants.len > source_namespace.max_grants) {
        return error.TooManyTrustGrants;
    }
    var store: TrustStore = .{};
    for (parsed.value.grants) |wire| {
        if (!source_namespace.validIdentifier(wire.plugin) or wire.plugin.len > source_namespace.max_id_bytes) {
            return error.InvalidPluginId;
        }
        var digest: source_namespace.Digest = undefined;
        if (wire.digest.len != digest.len * 2) {
            return error.InvalidDigest;
        }
        _ = std.fmt.hexToBytes(&digest, wire.digest) catch return error.InvalidDigest;
        var capabilities = source_namespace.CapabilitySet.initEmpty();
        for (wire.capabilities) |name| {
            const capability = try source_namespace.Capability.parse(name);
            if (capabilities.contains(capability)) {
                return error.DuplicateCapability;
            }
            capabilities.insert(capability);
        }
        var entry: StoredGrant = .{
            .plugin_len = @intCast(wire.plugin.len),
            .grant = .{
                .plugin_hash = source_namespace.stableId(wire.plugin),
                .digest = digest,
                .capabilities = capabilities,
            },
        };
        @memcpy(entry.plugin_bytes[0..wire.plugin.len], wire.plugin);
        for (store.entries[0..store.count]) |*previous|
            if (std.mem.eql(u8, previous.pluginId(), wire.plugin))
                return error.DuplicateTrustGrant;
        store.entries[store.count] = entry;
        store.count += 1;
    }
    return store;
}

/// Replaces or adds the digest-bound capabilities for one manifest.
///
/// ```zig
/// try store.upsert(&manifest, .{ .digest = digest, .capabilities = capabilities });
/// ```
pub fn upsert(store: *TrustStore, manifest: *const Manifest, update: GrantUpdate) !void {
    for (store.entries[0..store.count]) |*entry| {
        if (!std.mem.eql(u8, entry.pluginId(), manifest.id())) {
            continue;
        }
        entry.grant = .{
            .plugin_hash = source_namespace.stableId(manifest.id()),
            .digest = update.digest,
            .capabilities = update.capabilities,
        };
        return;
    }
    if (store.count == source_namespace.max_grants) {
        return error.TooManyTrustGrants;
    }
    var entry: StoredGrant = .{
        .plugin_len = manifest.id_len,
        .grant = .{
            .plugin_hash = source_namespace.stableId(manifest.id()),
            .digest = update.digest,
            .capabilities = update.capabilities,
        },
    };
    @memcpy(entry.plugin_bytes[0..manifest.id_len], manifest.id());
    store.entries[store.count] = entry;
    store.count += 1;
}

pub fn grants(store: *const TrustStore, buffer: *[source_namespace.max_grants]Grant) []const Grant {
    for (store.entries[0..store.count], 0..) |entry, index| buffer[index] = entry.grant;
    return buffer[0..store.count];
}

pub fn writeJson(store: *const TrustStore, writer: *std.Io.Writer) !void {
    try writer.writeAll("{\"version\":1,\"grants\":[");
    for (store.entries[0..store.count], 0..) |*entry, index| {
        if (index != 0) {
            try writer.writeByte(',');
        }
        try writer.print("{{\"plugin\":\"{s}\",\"digest\":\"", .{entry.pluginId()});
        for (entry.grant.digest) |byte| try writer.print("{x:0>2}", .{byte});
        try writer.writeAll("\",\"capabilities\":[");
        var capability_index: usize = 0;
        var iterator = entry.grant.capabilities.iterator();
        while (iterator.next()) |capability| {
            if (capability_index != 0) {
                try writer.writeByte(',');
            }
            try writer.print("\"{s}\"", .{capability.canonicalName()});
            capability_index += 1;
        }
        try writer.writeAll("]}");
    }
    try writer.writeAll("]}\n");
}

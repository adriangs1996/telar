//! Data-only plugin manifests, capabilities, and digest-bound trust grants.

const std = @import("std");

pub const manifest_api_version: u16 = 1;
pub const max_manifest_bytes = 64 * 1024;
pub const max_id_bytes = 64;
pub const max_version_bytes = 32;
pub const max_entry_bytes = 256;
pub const max_source_bytes = 256;
pub const max_revision_bytes = 128;
pub const max_actions = 64;
pub const max_action_bytes = 64;

pub const Capability = enum(u8) {
    workspace_read,
    workspace_write,
    process_spawn,
    network,
    clipboard_read,
    clipboard_write,
    notifications,
    history_read,
    history_write,
    proxy_tap,
    runtime_control,

    pub fn parse(name: []const u8) !Capability {
        inline for (std.meta.fields(Capability)) |field| {
            const value: Capability = @enumFromInt(field.value);
            if (std.mem.eql(u8, name, value.canonicalName())) {
                return value;
            }
        }
        return error.UnknownCapability;
    }

    pub fn canonicalName(capability: Capability) []const u8 {
        return switch (capability) {
            .workspace_read => "workspace.read",
            .workspace_write => "workspace.write",
            .process_spawn => "process.spawn",
            .network => "network",
            .clipboard_read => "clipboard.read",
            .clipboard_write => "clipboard.write",
            .notifications => "notifications",
            .history_read => "history.read",
            .history_write => "history.write",
            .proxy_tap => "proxy.tap",
            .runtime_control => "runtime.control",
        };
    }
};

pub const CapabilitySet = std.EnumSet(Capability);

pub const ActionName = struct {
    bytes: [max_action_bytes]u8 = undefined,
    len: u8,

    pub fn slice(value: *const ActionName) []const u8 {
        return value.bytes[0..value.len];
    }
};

pub const Manifest = struct {
    id_bytes: [max_id_bytes]u8 = undefined,
    id_len: u8,
    version_bytes: [max_version_bytes]u8 = undefined,
    version_len: u8,
    entry_bytes: [max_entry_bytes]u8 = undefined,
    entry_len: u16,
    source_bytes: [max_source_bytes]u8 = undefined,
    source_len: u16,
    revision_bytes: [max_revision_bytes]u8 = undefined,
    revision_len: u8,
    actions: [max_actions]ActionName = undefined,
    action_count: u8,
    capabilities: CapabilitySet,

    pub fn id(manifest: *const Manifest) []const u8 {
        return manifest.id_bytes[0..manifest.id_len];
    }

    pub fn version(manifest: *const Manifest) []const u8 {
        return manifest.version_bytes[0..manifest.version_len];
    }

    pub fn entry(manifest: *const Manifest) []const u8 {
        return manifest.entry_bytes[0..manifest.entry_len];
    }

    pub fn source(manifest: *const Manifest) []const u8 {
        return manifest.source_bytes[0..manifest.source_len];
    }

    pub fn revision(manifest: *const Manifest) []const u8 {
        return manifest.revision_bytes[0..manifest.revision_len];
    }

    pub fn hasAction(manifest: *const Manifest, name: []const u8) bool {
        for (manifest.actions[0..manifest.action_count]) |*candidate|
            if (std.mem.eql(u8, candidate.slice(), name)) return true;
        return false;
    }
};

const WireManifest = struct {
    const Source = struct { url: []const u8, revision: []const u8 };

    api_version: u16,
    id: []const u8,
    version: []const u8,
    entry: []const u8,
    source: Source,
    actions: []const []const u8 = &.{},
    capabilities: []const []const u8 = &.{},
};

pub fn parseManifest(gpa: std.mem.Allocator, source: []const u8) !Manifest {
    if (source.len > max_manifest_bytes) {
        return error.ManifestTooLarge;
    }
    const parsed = try std.json.parseFromSlice(WireManifest, gpa, source, .{
        .ignore_unknown_fields = false,
    });
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.api_version != manifest_api_version) {
        return error.IncompatibleManifestApi;
    }
    if (!validIdentifier(wire.id) or wire.id.len > max_id_bytes) {
        return error.InvalidPluginId;
    }
    if (wire.version.len == 0 or wire.version.len > max_version_bytes) {
        return error.InvalidVersion;
    }
    if (!validRelativePath(wire.entry) or wire.entry.len > max_entry_bytes) {
        return error.InvalidEntrypoint;
    }
    if (wire.source.url.len == 0 or wire.source.url.len > max_source_bytes) {
        return error.InvalidSource;
    }
    if (wire.source.revision.len == 0 or wire.source.revision.len > max_revision_bytes) {
        return error.InvalidRevision;
    }
    if (wire.actions.len > max_actions) {
        return error.TooManyActions;
    }

    var manifest: Manifest = .{
        .id_len = @intCast(wire.id.len),
        .version_len = @intCast(wire.version.len),
        .entry_len = @intCast(wire.entry.len),
        .source_len = @intCast(wire.source.url.len),
        .revision_len = @intCast(wire.source.revision.len),
        .action_count = @intCast(wire.actions.len),
        .capabilities = .initEmpty(),
    };
    @memcpy(manifest.id_bytes[0..wire.id.len], wire.id);
    @memcpy(manifest.version_bytes[0..wire.version.len], wire.version);
    @memcpy(manifest.entry_bytes[0..wire.entry.len], wire.entry);
    @memcpy(manifest.source_bytes[0..wire.source.url.len], wire.source.url);
    @memcpy(manifest.revision_bytes[0..wire.source.revision.len], wire.source.revision);
    for (wire.actions, 0..) |name, index| {
        if (!validIdentifier(name) or name.len > max_action_bytes) {
            return error.InvalidActionName;
        }
        for (wire.actions[0..index]) |previous|
            if (std.mem.eql(u8, previous, name)) return error.DuplicateAction;
        manifest.actions[index].len = @intCast(name.len);
        @memcpy(manifest.actions[index].bytes[0..name.len], name);
    }
    for (wire.capabilities) |name| {
        const capability = try Capability.parse(name);
        if (manifest.capabilities.contains(capability)) {
            return error.DuplicateCapability;
        }
        manifest.capabilities.insert(capability);
    }
    return manifest;
}

pub const Digest = [32]u8;

pub fn contentDigest(manifest_bytes: []const u8, entry_bytes: []const u8) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("telar-plugin-v1\x00");
    var length: [8]u8 = undefined;
    std.mem.writeInt(u64, &length, manifest_bytes.len, .little);
    hasher.update(&length);
    hasher.update(manifest_bytes);
    std.mem.writeInt(u64, &length, entry_bytes.len, .little);
    hasher.update(&length);
    hasher.update(entry_bytes);
    return hasher.finalResult();
}

pub const Grant = struct {
    plugin_hash: u64,
    digest: Digest,
    capabilities: CapabilitySet,

    pub fn allows(grant: Grant, plugin_id: []const u8, digest: Digest, capability: Capability) bool {
        return grant.plugin_hash == stableId(plugin_id) and
            std.mem.eql(u8, &grant.digest, &digest) and
            grant.capabilities.contains(capability);
    }
};

pub const max_grants = 64;

pub const StoredGrant = struct {
    plugin_bytes: [max_id_bytes]u8 = undefined,
    plugin_len: u8,
    grant: Grant,

    pub fn pluginId(stored: *const StoredGrant) []const u8 {
        return stored.plugin_bytes[0..stored.plugin_len];
    }
};

pub const TrustStore = struct {
    entries: [max_grants]StoredGrant = undefined,
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
        if (parsed.value.grants.len > max_grants) {
            return error.TooManyTrustGrants;
        }
        var store: TrustStore = .{};
        for (parsed.value.grants) |wire| {
            if (!validIdentifier(wire.plugin) or wire.plugin.len > max_id_bytes) {
                return error.InvalidPluginId;
            }
            var digest: Digest = undefined;
            if (wire.digest.len != digest.len * 2) {
                return error.InvalidDigest;
            }
            _ = std.fmt.hexToBytes(&digest, wire.digest) catch return error.InvalidDigest;
            var capabilities = CapabilitySet.initEmpty();
            for (wire.capabilities) |name| {
                const capability = try Capability.parse(name);
                if (capabilities.contains(capability)) {
                    return error.DuplicateCapability;
                }
                capabilities.insert(capability);
            }
            var entry: StoredGrant = .{
                .plugin_len = @intCast(wire.plugin.len),
                .grant = .{
                    .plugin_hash = stableId(wire.plugin),
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

    pub fn upsert(store: *TrustStore, manifest: *const Manifest, digest: Digest, capabilities: CapabilitySet) !void {
        for (store.entries[0..store.count]) |*entry| {
            if (!std.mem.eql(u8, entry.pluginId(), manifest.id())) {
                continue;
            }
            entry.grant = .{
                .plugin_hash = stableId(manifest.id()),
                .digest = digest,
                .capabilities = capabilities,
            };
            return;
        }
        if (store.count == max_grants) {
            return error.TooManyTrustGrants;
        }
        var entry: StoredGrant = .{
            .plugin_len = manifest.id_len,
            .grant = .{
                .plugin_hash = stableId(manifest.id()),
                .digest = digest,
                .capabilities = capabilities,
            },
        };
        @memcpy(entry.plugin_bytes[0..manifest.id_len], manifest.id());
        store.entries[store.count] = entry;
        store.count += 1;
    }

    pub fn grants(store: *const TrustStore, buffer: *[max_grants]Grant) []const Grant {
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
};

pub fn stableId(name: []const u8) u64 {
    var hash: u64 = 0xcbf29ce484222325;
    for (name) |byte| {
        hash ^= byte;
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn validIdentifier(value: []const u8) bool {
    if (value.len == 0 or value[0] == '.' or value[value.len - 1] == '.') {
        return false;
    }
    var previous_dot = false;
    for (value) |byte| {
        if (byte == '.') {
            if (previous_dot) {
                return false;
            }
            previous_dot = true;
            continue;
        }
        previous_dot = false;
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') {
            return false;
        }
    }
    return true;
}

fn validRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) {
        return false;
    }
    var components = std.mem.splitAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (component.len == 0 or std.mem.eql(u8, component, ".") or
            std.mem.eql(u8, component, ".."))
        {
            return false;
        }
    }
    return true;
}

test "manifest parsing is data-only and rejects traversal" {
    const manifest = try parseManifest(std.testing.allocator,
        \\{
        \\  "api_version": 1,
        \\  "id": "dev.telar.sample",
        \\  "version": "1.2.3",
        \\  "entry": "plugin.lua",
        \\  "source": { "url": "https://example.invalid/sample", "revision": "abc123" },
        \\  "actions": ["open", "close"],
        \\  "capabilities": ["history.read"]
        \\}
    );
    try std.testing.expectEqualStrings("dev.telar.sample", manifest.id());
    try std.testing.expect(manifest.capabilities.contains(.history_read));
    try std.testing.expect(manifest.hasAction("open"));
    try std.testing.expectError(error.InvalidEntrypoint, parseManifest(std.testing.allocator,
        \\{"api_version":1,"id":"sample","version":"1","entry":"../escape.lua","source":{"url":"local","revision":"dev"}}
    ));
}

test "trust grants are invalidated by content changes" {
    const first = contentDigest("manifest", "return 1");
    const second = contentDigest("manifest", "return 2");
    var capabilities = CapabilitySet.initEmpty();
    capabilities.insert(.history_read);
    const grant: Grant = .{
        .plugin_hash = stableId("sample"),
        .digest = first,
        .capabilities = capabilities,
    };
    try std.testing.expect(grant.allows("sample", first, .history_read));
    try std.testing.expect(!grant.allows("sample", second, .history_read));
    try std.testing.expect(!grant.allows("sample", first, .network));
}

test "trust store round trips digest-bound capability grants" {
    const manifest = try parseManifest(std.testing.allocator,
        \\{"api_version":1,"id":"sample","version":"1","entry":"plugin.lua","source":{"url":"local","revision":"dev"},"capabilities":["history.read"]}
    );
    var capabilities = CapabilitySet.initEmpty();
    capabilities.insert(.history_read);
    var store: TrustStore = .{};
    const digest = contentDigest("manifest", "entry");
    try store.upsert(&manifest, digest, capabilities);
    var bytes: [4096]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try store.writeJson(&writer);
    const decoded = try TrustStore.parse(std.testing.allocator, writer.buffered());
    try std.testing.expectEqual(@as(u8, 1), decoded.count);
    try std.testing.expect(decoded.entries[0].grant.allows(
        "sample",
        digest,
        .history_read,
    ));
}

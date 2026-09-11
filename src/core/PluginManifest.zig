const Manifest = @This();
const source_namespace = @import("plugin.zig");
const ActionName = @import("ActionName.zig");
const std = @import("std");
id_bytes: [source_namespace.max_id_bytes]u8 = undefined,
id_len: u8,
version_bytes: [source_namespace.max_version_bytes]u8 = undefined,
version_len: u8,
entry_bytes: [source_namespace.max_entry_bytes]u8 = undefined,
entry_len: u16,
source_bytes: [source_namespace.max_source_bytes]u8 = undefined,
source_len: u16,
revision_bytes: [source_namespace.max_revision_bytes]u8 = undefined,
revision_len: u8,
actions: [source_namespace.max_actions]ActionName = undefined,
action_count: u8,
capabilities: source_namespace.CapabilitySet,

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

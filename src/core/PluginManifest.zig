const plugin = @import("plugin.zig");
const std = @import("std");
const Manifest = @This();

id_bytes: [plugin.max_id_bytes]u8 = undefined,
id_len: u8,
version_bytes: [plugin.max_version_bytes]u8 = undefined,
version_len: u8,
entry_bytes: [plugin.max_entry_bytes]u8 = undefined,
entry_len: u16,
source_bytes: [plugin.max_source_bytes]u8 = undefined,
source_len: u16,
revision_bytes: [plugin.max_revision_bytes]u8 = undefined,
revision_len: u8,
actions: [plugin.max_actions]ActionName = undefined,
action_count: u8,
capabilities: plugin.CapabilitySet,

pub fn id(self: *const Manifest) []const u8 {
    return self.id_bytes[0..self.id_len];
}

pub fn version(self: *const Manifest) []const u8 {
    return self.version_bytes[0..self.version_len];
}

pub fn entry(self: *const Manifest) []const u8 {
    return self.entry_bytes[0..self.entry_len];
}

pub fn source(self: *const Manifest) []const u8 {
    return self.source_bytes[0..self.source_len];
}

pub fn revision(self: *const Manifest) []const u8 {
    return self.revision_bytes[0..self.revision_len];
}

pub fn hasAction(self: *const Manifest, name: []const u8) bool {
    for (self.actions[0..self.action_count]) |*candidate|
        if (std.mem.eql(u8, candidate.slice(), name)) return true;
    return false;
}

const ActionName = struct {
    bytes: [plugin.max_action_bytes]u8 = undefined,
    len: u8,

    pub fn slice(self: *const ActionName) []const u8 {
        return self.bytes[0..self.len];
    }
};

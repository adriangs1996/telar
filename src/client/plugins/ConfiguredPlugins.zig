const std = @import("std");
const Snapshot = @import("../config/Snapshot.zig");
const Registry = @import("Registry.zig");
const Package = @import("Package.zig");
const Catalog = @This();
snapshot: *const Snapshot,
registry: *const Registry,

/// Maps configuration order to the loaded enabled subset. Example: `const package = catalog.package(2);`
pub fn package(self: Catalog, index: usize) ?*const Package {
    if (index >= self.snapshot.plugin_count or !self.snapshot.plugins[index].enabled) {
        return null;
    }

    var loaded: usize = 0;
    for (self.snapshot.plugins[0..index]) |spec| {
        if (spec.enabled) {
            loaded += 1;
        }
    }

    return if (loaded < self.registry.count) &self.registry.packages[loaded] else null;
}

/// Accepts either the configured path or a loaded manifest ID. Example: `const index = try catalog.find("git-tools");`
pub fn find(self: Catalog, name: []const u8) !usize {
    for (self.snapshot.plugins[0..self.snapshot.plugin_count], 0..) |*spec, index| {
        if (std.mem.eql(u8, spec.path(), name)) {
            return index;
        }

        if (self.package(index)) |loaded| {
            if (std.mem.eql(u8, loaded.manifest.id(), name)) {
                return index;
            }
        }
    }

    return error.PluginNotConfigured;
}

test "disabled configuration entries do not consume a loaded package" {
    var snapshot: Snapshot = .{};
    snapshot.plugin_count = 2;
    snapshot.plugins[0] = .{ .path_len = 1, .enabled = false };
    snapshot.plugins[0].path_bytes[0] = 'a';
    snapshot.plugins[1] = .{ .path_len = 1, .enabled = true };
    snapshot.plugins[1].path_bytes[0] = 'b';
    var registry: Registry = .{};
    registry.count = 1;
    const catalog: Catalog = .{ .snapshot = &snapshot, .registry = &registry };
    try std.testing.expect(catalog.package(0) == null);
    try std.testing.expect(catalog.package(1).? == &registry.packages[0]);
    try std.testing.expectEqual(@as(usize, 0), try catalog.find("a"));
}

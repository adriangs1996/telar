const data = @import("model");
const std = @import("std");
const Snapshot = @import("../config/Snapshot.zig");
const Overrides = @This();
items: [data.config_values.max_plugins]data.PluginOverride = undefined,
count: u8 = 0,

/// Replaces one owned override without retaining configuration memory. Example: `try overrides.set(value);`
pub fn set(self: *Overrides, value: data.PluginOverride) !void {
    for (self.items[0..self.count]) |*item| {
        if (std.mem.eql(u8, item.spec.path(), value.spec.path())) {
            const identity = value.plugin_id orelse item.plugin_id;
            item.* = value;
            item.plugin_id = identity;
            return;
        }
    }

    if (self.count == self.items.len) {
        return error.TooManyPluginOverrides;
    }

    self.items[self.count] = value;
    self.count += 1;
}

/// Returns pending policy, when present. Example: `const enabled = overrides.requested(spec.path());`
pub fn requested(self: *const Overrides, path: []const u8) ?bool {
    for (self.items[0..self.count]) |*item| {
        if (std.mem.eql(u8, item.spec.path(), path)) {
            return item.spec.enabled;
        }
    }

    return null;
}

/// Applies a captured policy to fresh worker-owned configuration. Example: `overrides.apply(&generation.snapshot);`
pub fn apply(self: *const Overrides, snapshot: *Snapshot) void {
    for (snapshot.plugins[0..snapshot.plugin_count]) |*spec| {
        if (self.requested(spec.path())) |enabled| {
            spec.enabled = enabled;
        }
    }

    var retained: u16 = 0;
    for (snapshot.bindings[0..snapshot.binding_count], 0..) |binding, index| {
        if (binding.action == .plugin and self.disabled(binding.action.plugin.plugin, snapshot)) {
            continue;
        }

        snapshot.bindings[retained] = binding;
        snapshot.bindings_prefixed[retained] = snapshot.bindings_prefixed[index];
        retained += 1;
    }

    snapshot.binding_count = retained;
}

fn disabled(self: *const Overrides, id: u64, snapshot: *const Snapshot) bool {
    for (self.items[0..self.count]) |item| {
        if (!item.spec.enabled and item.plugin_id == id) {
            for (snapshot.plugins[0..snapshot.plugin_count]) |*spec| {
                if (!spec.enabled and std.mem.eql(u8, spec.path(), item.spec.path())) {
                    return true;
                }
            }
        }
    }

    return false;
}

test "captured overrides are independent and disabling removes only that plugin's bindings" {
    var original: Snapshot = .{};
    original.plugin_count = 1;
    original.plugins[0] = .{ .path_len = 1 };
    original.plugins[0].path_bytes[0] = 'x';
    original.binding_count = 2;
    original.bindings[0] = try data.config_values.ConfiguredBinding.init(&.{original.prefix}, .{ .plugin = .{ .plugin = 7, .action = 8 } });
    original.bindings_prefixed[0] = true;
    original.bindings[1] = try data.config_values.ConfiguredBinding.init(&.{original.prefix}, .toggle_sidebar);
    original.bindings_prefixed[1] = false;
    var overrides: Overrides = .{};
    var value: data.PluginOverride = .{ .spec = original.plugins[0], .plugin_id = 7 };
    value.spec.enabled = false;
    try overrides.set(value);
    const captured = overrides;
    value.spec.enabled = true;
    try overrides.set(value);
    var disabled_snapshot = original;
    captured.apply(&disabled_snapshot);
    try std.testing.expect(!disabled_snapshot.plugins[0].enabled);
    try std.testing.expectEqual(@as(u16, 1), disabled_snapshot.binding_count);
    try std.testing.expect(disabled_snapshot.bindings[0].action == .toggle_sidebar);
    try std.testing.expect(!disabled_snapshot.bindings_prefixed[0]);
    var moved = original;
    moved.plugins[0].path_bytes[0] = 'y';
    captured.apply(&moved);
    try std.testing.expectEqual(@as(u16, 2), moved.binding_count);
    try std.testing.expect(moved.plugins[0].enabled);
    overrides.apply(&original);
    try std.testing.expect(original.plugins[0].enabled);
    try std.testing.expectEqual(@as(u16, 2), original.binding_count);
}

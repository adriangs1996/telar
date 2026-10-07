const data = @import("model");
const std = @import("std");
const Snapshot = @import("../config/Snapshot.zig");
const Overrides = @This();
// SAFETY: set writes a new override before increasing count; lookup and application visit only that initialized prefix.
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

const data = @import("model");
const ConfigReloadState = @import("ConfigReloadState.zig");
const std = @import("std");
const Loaded = @import("Loaded.zig");
const config_reload = @import("config_reload.zig");
const RejectContext = @This();

state: *ConfigReloadState,
gpa: std.mem.Allocator,
loaded: Loaded,

pub fn reject(self: RejectContext, comptime format: []const u8, args: anytype) config_reload.Outcome {
    var diagnostic: data.Diagnostic = .{};
    diagnostic.set(format, args);
    self.state.clearOrphans();
    self.state.mtime_ns = self.loaded.mtime_ns;
    self.loaded.generation.deinit();
    self.gpa.destroy(self.loaded.registry);
    self.gpa.destroy(self.loaded.trust_store);

    return .{ .rejected = diagnostic };
}

const RejectContext = @This();
const State = @import("ConfigReloadState.zig");
const std = @import("std");
const Loaded = @import("Loaded.zig");
const source_namespace = @import("config_reload.zig");
const lua_config = @import("../../config/root.zig");
state: *State,
gpa: std.mem.Allocator,
loaded: Loaded,

pub fn reject(context: RejectContext, comptime format: []const u8, args: anytype) source_namespace.Outcome {
    var diagnostic: lua_config.Diagnostic = .{};
    diagnostic.set(format, args);
    context.state.clearOrphans();
    context.state.mtime_ns = context.loaded.mtime_ns;
    context.loaded.generation.deinit();
    context.gpa.destroy(context.loaded.registry);
    context.gpa.destroy(context.loaded.trust_store);

    return .{ .rejected = diagnostic };
}

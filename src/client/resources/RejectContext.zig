const ConfigReloadState = @import("ConfigReloadState.zig");
const std = @import("std");
const Loaded = @import("Loaded.zig");
const config_reload = @import("config_reload.zig");
const DiagnosticType = @import("../config/Diagnostic.zig");
const RejectContext = @This();

state: *ConfigReloadState,
gpa: std.mem.Allocator,
loaded: Loaded,

pub fn reject(context: RejectContext, comptime format: []const u8, args: anytype) config_reload.Outcome {
    var diagnostic: DiagnosticType = .{};
    diagnostic.set(format, args);
    context.state.clearOrphans();
    context.state.mtime_ns = context.loaded.mtime_ns;
    context.loaded.generation.deinit();
    context.gpa.destroy(context.loaded.registry);
    context.gpa.destroy(context.loaded.trust_store);

    return .{ .rejected = diagnostic };
}

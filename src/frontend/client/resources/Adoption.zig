/// Everything a validated reload hands over: the owned configuration
/// objects and the values already compiled from them.
const Adoption = @This();
const lua_config = @import("../../config/root.zig");
const plugin_broker = @import("../../plugins/root.zig");
const core = @import("telar-core");
const source_namespace = @import("config_reload.zig");
const std = @import("std");
generation: *lua_config.Generation,
registry: *plugin_broker.Registry,
trust_store: *core.plugin.TrustStore,
router: source_namespace.InputRouter,
sidebar_rendering: source_namespace.kitty.SidebarRendering,

/// Releases an adoption that no client accepted.
///
/// ```zig
/// errdefer adoption.deinit(gpa);
/// ```
pub fn deinit(adoption: Adoption, gpa: std.mem.Allocator) void {
    adoption.generation.deinit();
    gpa.destroy(adoption.registry);
    gpa.destroy(adoption.trust_store);
}

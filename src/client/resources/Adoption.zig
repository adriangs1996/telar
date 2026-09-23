const data = @import("model");
const core = @import("telar-core");
const GenerationType = @import("../config/Generation.zig");
const RegistryType = @import("../plugins/Registry.zig");
const RouterConfigType = @import("../input/RouterConfig.zig");
const std = @import("std");
/// Everything a validated reload hands over: the owned configuration
/// objects and the values already compiled from them.
const Adoption = @This();

generation: *GenerationType,
registry: *RegistryType,
trust_store: *core.TrustStore,
/// Bindings the adapter compiles into its own router when it adopts.
input: RouterConfigType,
sidebar_rendering: data.SidebarRendering,

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

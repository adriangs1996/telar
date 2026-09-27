const data = @import("model");
const core = @import("telar-core");
const Generation = @import("../config/Generation.zig");
const Registry = @import("../plugins/Registry.zig");
const RouterConfig = @import("../input/RouterConfig.zig");
const std = @import("std");
/// Everything a validated reload hands over: the owned configuration
/// objects and the values already compiled from them.
const Adoption = @This();

generation: *Generation,
registry: *Registry,
trust_store: *core.TrustStore,
/// Bindings the adapter compiles into its own router when it adopts.
input: RouterConfig,

/// Releases an adoption that no client accepted.
///
/// ```zig
/// errdefer adoption.deinit(gpa);
/// ```
pub fn deinit(self: Adoption, gpa: std.mem.Allocator) void {
    self.generation.deinit();
    gpa.destroy(self.registry);
    gpa.destroy(self.trust_store);
}

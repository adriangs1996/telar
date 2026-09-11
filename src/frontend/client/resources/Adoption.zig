const GenerationType = @import("../../config/Generation.zig");
const RegistryType = @import("../../plugins/Registry.zig");
const TrustStoreType = @import("telar-core").TrustStore;
const host_inputs = @import("../controllers/input/host_inputs.zig");
const capabilities = @import("../../graphics/capabilities.zig");
const std = @import("std");
/// Everything a validated reload hands over: the owned configuration
/// objects and the values already compiled from them.
const Adoption = @This();

generation: *GenerationType,
registry: *RegistryType,
trust_store: *TrustStoreType,
router: host_inputs.Router,
sidebar_rendering: capabilities.SidebarRendering,

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

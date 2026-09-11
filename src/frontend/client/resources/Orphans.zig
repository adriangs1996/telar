const GenerationType = @import("../../config/Generation.zig");
const RegistryType = @import("../../plugins/Registry.zig");
const TrustStoreType = @import("telar-core").TrustStore;
const Orphans = @This();

generation: ?*GenerationType = null,
registry: ?*RegistryType = null,
trust: ?*TrustStoreType = null,

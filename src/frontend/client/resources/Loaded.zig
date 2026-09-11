const GenerationType = @import("../../config/Generation.zig");
const RegistryType = @import("../../plugins/Registry.zig");
const TrustStoreType = @import("telar-core").TrustStore;
const Loaded = @This();

generation: *GenerationType,
registry: *RegistryType,
trust_store: *TrustStoreType,
mtime_ns: i128,

const core = @import("telar-core");
const GenerationType = @import("../config/Generation.zig");
const RegistryType = @import("../plugins/Registry.zig");
const Loaded = @This();

generation: *GenerationType,
registry: *RegistryType,
trust_store: *core.TrustStore,
mtime_ns: i128,

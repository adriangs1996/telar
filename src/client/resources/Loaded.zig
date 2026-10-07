const core = @import("telar-core");
const Generation = @import("../config/Generation.zig");
const Registry = @import("../plugins/Registry.zig");

generation: *Generation,
registry: *Registry,
trust_store: *core.TrustStore,
mtime_ns: i128,

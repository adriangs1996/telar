const core = @import("telar-core");
const GenerationType = @import("../config/Generation.zig");
const RegistryType = @import("../plugins/Registry.zig");
const Orphans = @This();

generation: ?*GenerationType = null,
registry: ?*RegistryType = null,
trust: ?*core.TrustStore = null,

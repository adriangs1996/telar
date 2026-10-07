const core = @import("telar-core");
const Generation = @import("../config/Generation.zig");
const Registry = @import("../plugins/Registry.zig");

generation: ?*Generation = null,
registry: ?*Registry = null,
trust: ?*core.TrustStore = null,

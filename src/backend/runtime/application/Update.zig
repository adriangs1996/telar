const core = @import("telar-core");
const Sources = @import("Sources.zig");
const Update = @This();

identity: core.ClientIdentity,
layout: core.ClientLayoutUpdateView,
sources: Sources,

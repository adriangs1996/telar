const ClientIdentityType = @import("telar-core").ClientIdentity;
const ClientLayoutUpdateViewType = @import("telar-core").ClientLayoutUpdateView;
const Sources = @import("Sources.zig");
const Update = @This();

identity: ClientIdentityType,
layout: ClientLayoutUpdateViewType,
sources: Sources,

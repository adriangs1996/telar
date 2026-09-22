const core = @import("telar-core");
const EntryInput = @This();

entry: c_int,
manifest: *core.AgentManifest,
position: usize,

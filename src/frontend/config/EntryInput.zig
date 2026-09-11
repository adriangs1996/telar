const AgentManifest = @import("telar-core").AgentManifest;
const EntryInput = @This();

entry: c_int,
manifest: *AgentManifest,
position: usize,

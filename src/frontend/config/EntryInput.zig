const EntryInput = @This();
const source_namespace = @import("agents.zig");
entry: c_int,
manifest: *source_namespace.Manifest,
position: usize,

const data = @import("model");
const client = @import("telar-client");
const Presented = @This();

presented_ns: u64,
commit: data.PresentationCommit,

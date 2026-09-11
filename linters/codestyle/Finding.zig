const diagnostic = @import("diagnostic.zig");
const Finding = @This();

rule: diagnostic.Rule,
detail: usize = 0,

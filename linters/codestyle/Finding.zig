const Finding = @This();
const diagnostic = @import("diagnostic.zig");
rule: diagnostic.Rule,
detail: usize = 0,

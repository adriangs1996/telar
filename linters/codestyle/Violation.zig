const diagnostic = @import("diagnostic.zig");
const Violation = @This();

rule: diagnostic.Rule,
line: usize,
column: usize,
detail: usize = 0,

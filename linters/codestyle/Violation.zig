const Violation = @This();
const source_namespace = @import("diagnostic.zig");
rule: source_namespace.Rule,
line: usize,
column: usize,
detail: usize = 0,

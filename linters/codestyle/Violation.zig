const diagnostic = @import("diagnostic.zig");

rule: diagnostic.Rule,
line: usize,
column: usize,
detail: usize = 0,

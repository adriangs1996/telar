const ExecRequest = @This();

file: [*:0]const u8,
argv: [*:null]const ?[*:0]const u8,
environment: [*:null]const ?[*:0]const u8,
path: []const u8,

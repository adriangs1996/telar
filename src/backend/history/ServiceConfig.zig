const core = @import("telar-core");
const Config = @This();

database_path: [:0]const u8,
filters: core.Filters = .{},
capture_output: bool = false,

const core = @import("telar-core");

database_path: [:0]const u8,
filters: core.Filters = .{},
capture_output: bool = false,

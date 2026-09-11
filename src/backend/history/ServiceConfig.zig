const FiltersType = @import("telar-core").Filters;
const Config = @This();

database_path: [:0]const u8,
filters: FiltersType = .{},
capture_output: bool = false,

const SourceInput = @This();

source: []const u8,
source_name: [*:0]const u8,
config_dir: []const u8 = ".",
number: u64,
profile: ?[]const u8 = null,

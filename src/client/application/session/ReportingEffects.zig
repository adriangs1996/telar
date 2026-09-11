const ReportingEffects = @This();

context: *anyopaque,
report: *const fn (*anyopaque, []const u8) void,

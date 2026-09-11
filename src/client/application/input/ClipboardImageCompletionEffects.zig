const CompletionEffects = @This();

context: *anyopaque,
adopt: *const fn (*anyopaque) anyerror!bool,
resize: *const fn (*anyopaque) anyerror!void,

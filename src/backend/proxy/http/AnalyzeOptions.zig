const types = @import("../../agent/types.zig");
const AnalyzeOptions = @This();

is_response: bool,
response_to_head: bool,
dialect: types.ApiDialect = .unknown,

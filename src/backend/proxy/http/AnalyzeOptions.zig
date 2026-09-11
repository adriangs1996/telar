const AnalyzeOptions = @This();
const provider = @import("../provider/request_support.zig");
is_response: bool,
response_to_head: bool,
dialect: provider.ApiDialect = .unknown,

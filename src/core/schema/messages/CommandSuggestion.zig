const id = @import("../id.zig");
const types = @import("../types.zig");
/// The engine's answer to `suggest_command`. `text` is empty unless
/// `status == .ready`.
request_id: id.RequestId,
status: types.SuggestionStatus,
text: []const u8 = "",

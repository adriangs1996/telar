/// The engine's answer to `suggest_command`. `text` is empty unless
/// `status == .ready`.
const CommandSuggestion = @This();
const source_namespace = @import("suggestion.zig");
request_id: source_namespace.RequestId,
status: source_namespace.SuggestionStatus,
text: []const u8 = "",

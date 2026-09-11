/// Builds the storable rendering of one exchange. Bodies are deliberately not
/// persisted: prompts, replies, and tool payloads may contain credentials for
/// which no generic redactor can provide a safety guarantee.
const ExchangeContent = @This();

request_head: []const u8,
request_body: []const u8,
response_head: []const u8,
response_body: []const u8,

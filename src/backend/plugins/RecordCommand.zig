const RecordCommand = @This();

command: []const u8,
cwd: []const u8,
provider: []const u8,
tool_call_id: []const u8,
session: ?[]const u8,
exit_code: i32,
started_at_ms: i64,
duration_ms: u64,
redact: bool,

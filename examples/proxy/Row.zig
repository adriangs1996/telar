/// One row. Every tap fills the columns it owns and leaves the rest null.
const Row = @This();

at_ms: i64,
kind: Kind,
/// Command id or connection id, so an `opened`/`closed` pair can be joined.
ref: ?i64 = null,
command: ?[]const u8 = null,
exit_status: ?i64 = null,
duration_ms: ?i64 = null,
host: ?[]const u8 = null,
port: ?i64 = null,
bytes_up: ?i64 = null,
bytes_down: ?i64 = null,
/// Resolved text the command printed. Redaction belongs here, before the
/// bytes reach disk — see the note in `Timeline.append`.
output: ?[]const u8 = null,
truncated: ?i64 = null,

pub const Kind = enum {
    command_started,
    command_finished,
    upstream_opened,
    upstream_closed,
    upstream_exchange,
};

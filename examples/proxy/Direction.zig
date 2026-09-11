const SessionType = @import("Session.zig");
/// Reads one message from `from`, forwards it to `to`, and reports what it was.
/// `scratch` holds the head; `capture` receives up to its own length of body.
/// Returns null when the peer is done talking.
const Direction = @This();

from: SessionType.Side,
to: SessionType.Side,
is_response: bool,

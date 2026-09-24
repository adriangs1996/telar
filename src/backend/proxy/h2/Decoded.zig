const Decoded = @This();

status_code: u16 = 0,
request: bool = false,
/// Bit `i` set: watched route `i` matched the `:method` field.
method_routes: u64 = 0,
/// Bit `i` set: watched route `i` matched the `:path` field.
path_routes: u64 = 0,
content_type_seen: bool = false,
event_stream: bool = false,
identity_encoding: bool = true,
metadata_valid: bool = true,

/// A request whose method and path both match one watched route.
pub fn isWatched(self: Decoded) bool {
    return self.request and self.method_routes & self.path_routes != 0;
}

pub fn hasObservableSseBody(self: Decoded) bool {
    return self.metadata_valid and self.content_type_seen and
        self.event_stream and self.identity_encoding;
}

/// What the relay saw happen to one stream.
const Lifecycle = @This();

stage: Stage,
stream_id: u32,
status_code: u16,
/// A request whose method and path match one of the watched routes.
watched: bool = false,

pub const Stage = enum {
    /// A request head opened the stream.
    request_started,
    /// Response DATA arrived.
    response_activity,
    /// The response ended the stream; `status_code` is its final status.
    response_ended,
    /// RST_STREAM closed the stream.
    stream_reset,
    /// GOAWAY arrived while responses were still open; stream zero.
    connection_lost,
};

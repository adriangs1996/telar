const RequestBodyObserver = @This();
const provider = @import("../provider/root.zig");
const capture = @import("../capture/root.zig");
const http = @import("../http/root.zig");
request: *provider.RequestObserver,
capture_half: ?*capture.Half = null,

/// Feeds one already-forwarded payload fragment to request classification.
///
/// ```zig
/// observer.observe(.{ .payload = bytes, .forwarded_bytes = bytes.len });
/// ```
pub fn observe(observer: RequestBodyObserver, fragment: http.BodyFragment) void {
    observer.request.feed(fragment.payload);
    if (observer.capture_half) |half| {
        _ = half.append(.request_body, fragment.payload);
    }
}

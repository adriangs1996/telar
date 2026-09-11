const Observer = @import("../provider/Observer.zig");
const HalfType = @import("../capture/Half.zig");
const Fragment = @import("../http/Fragment.zig");
const RequestBodyObserver = @This();

request: *Observer,
capture_half: ?*HalfType = null,

/// Feeds one already-forwarded payload fragment to request classification.
///
/// ```zig
/// observer.observe(.{ .payload = bytes, .forwarded_bytes = bytes.len });
/// ```
pub fn observe(observer: RequestBodyObserver, fragment: Fragment) void {
    observer.request.feed(fragment.payload);
    if (observer.capture_half) |half| {
        _ = half.append(.request_body, fragment.payload);
    }
}

const Observer = @import("../provider/Observer.zig");
const Half = @import("../capture/Half.zig");
const Fragment = @import("../http/Fragment.zig");
const RequestBodyObserver = @This();

request: *Observer,
capture_half: ?*Half = null,

/// Feeds one already-forwarded payload fragment to request classification.
///
/// ```zig
/// observer.observe(.{ .payload = bytes, .forwarded_bytes = bytes.len });
/// ```
pub fn observe(self: RequestBodyObserver, fragment: Fragment) void {
    self.request.feed(fragment.payload);
    if (self.capture_half) |half| {
        _ = half.append(.request_body, fragment.payload);
    }
}

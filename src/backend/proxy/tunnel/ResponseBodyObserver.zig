const Exchange = @import("Exchange.zig");
const ResponseObserver = @import("../provider/ResponseObserver.zig");
const Half = @import("../capture/Half.zig");
const ResponseObserverOptions = @import("ResponseObserverOptions.zig");
const Fragment = @import("../http/Fragment.zig");
const ResponseBodyObserver = @This();

exchange: *Exchange,
response: ResponseObserver,
inspect_payload: bool,
capture_half: ?*Half,

pub fn init(exchange: *Exchange, options: ResponseObserverOptions) ResponseBodyObserver {
    return .{
        .exchange = exchange,
        .response = .init(exchange.dialect),
        .inspect_payload = options.inspect_payload,
        .capture_half = options.capture_half,
    };
}

/// Publishes forwarding activity and inspects eligible SSE payload bytes
/// for provider turn completion.
///
/// ```zig
/// observer.observe(.{ .payload = bytes, .forwarded_bytes = bytes.len });
/// ```
pub fn observe(self: *ResponseBodyObserver, fragment: Fragment) void {
    if (self.capture_half) |half| {
        _ = half.append(.response_body, fragment.payload);
    }

    if (fragment.forwarded_bytes != 0) {
        self.exchange.publish(.response_activity, 0);
    }

    if (self.inspect_payload and fragment.payload.len != 0) {
        if (self.response.dialect == .anthropic_messages) {
            self.exchange.record(.claude_sse_payload_fragment);
        }

        if (self.response.feed(fragment.payload)) {
            self.exchange.publish(.provider_turn_completed, 0);
        }
    }
}

pub fn deinit(self: *ResponseBodyObserver) void {
    self.response.deinit();
    self.inspect_payload = false;
    self.capture_half = null;
}

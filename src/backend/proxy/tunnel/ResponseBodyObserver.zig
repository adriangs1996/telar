const ExchangeType = @import("Exchange.zig");
const ResponseObserverType = @import("../provider/ResponseObserver.zig");
const HalfType = @import("../capture/Half.zig");
const ResponseObserverOptions = @import("ResponseObserverOptions.zig");
const Fragment = @import("../http/Fragment.zig");
const ResponseBodyObserver = @This();

exchange: *ExchangeType,
response: ResponseObserverType,
inspect_payload: bool,
capture_half: ?*HalfType,

pub fn init(exchange: *ExchangeType, options: ResponseObserverOptions) ResponseBodyObserver {
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
pub fn observe(observer: *ResponseBodyObserver, fragment: Fragment) void {
    if (observer.capture_half) |half| {
        _ = half.append(.response_body, fragment.payload);
    }

    if (fragment.forwarded_bytes != 0) {
        observer.exchange.publish(.response_activity, 0);
    }

    if (observer.inspect_payload and fragment.payload.len != 0) {
        if (observer.response.dialect == .anthropic_messages) {
            observer.exchange.record(.claude_sse_payload_fragment);
        }

        if (observer.response.feed(fragment.payload)) {
            observer.exchange.publish(.provider_turn_completed, 0);
        }
    }
}

pub fn deinit(observer: *ResponseBodyObserver) void {
    observer.response.deinit();
    observer.inspect_payload = false;
    observer.capture_half = null;
}

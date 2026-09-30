//! An HTTP relay that forwards intercepted HTTP/1.1 and HTTP/2 traffic
//! byte for byte while it reports what it forwarded: heads, de-framed body
//! fragments, and HTTP/2 stream stages. Requests matching watched routes are
//! flagged; no rule decides what a request means.

pub const http1 = @import("http1/http1.zig");
pub const http2 = @import("http2/http2.zig");
pub const RouteMatch = @import("RouteMatch.zig");
pub const header_rules = @import("header_rules.zig");
pub const observer_hooks = @import("observer_hooks.zig");

test {
    _ = @import("RouteMatch.zig");
    _ = @import("header_rules.zig");
    _ = @import("observer_hooks.zig");
    _ = @import("http1/FramingLine.zig");
    _ = @import("http1/AnalyzeOptions.zig");
    _ = @import("http1/ConnectionCapture.zig");
    _ = @import("http1/ConnectionIntegration.zig");
    _ = @import("http1/ExchangeCapture.zig");
    _ = @import("http1/ExchangeState.zig");
    _ = @import("http1/FakeSession.zig");
    _ = @import("http1/Fragment.zig");
    _ = @import("http1/GenericConnection.zig");
    _ = @import("http1/GenericExchange.zig");
    _ = @import("http1/Head.zig");
    _ = @import("http1/IgnoreTestObserver.zig");
    _ = @import("http1/Message.zig");
    _ = @import("http1/MessageRoute.zig");
    _ = @import("http1/RequestHead.zig");
    _ = @import("http1/ResponseHead.zig");
    _ = @import("http1/Route.zig");
    _ = @import("http1/body.zig");
    _ = @import("http1/connection.zig");
    _ = @import("http1/head_support.zig");
    _ = @import("http1/http1.zig");
    _ = @import("http1/test_support.zig");
    _ = @import("http1/types.zig");
    _ = @import("http2/BodyCollector.zig");
    _ = @import("http2/Capture.zig");
    _ = @import("http2/Decoded.zig");
    _ = @import("http2/GenericConnection.zig");
    _ = @import("http2/H2Route.zig");
    _ = @import("http2/header_memory.zig");
    _ = @import("http2/IntegrationContext.zig");
    _ = @import("http2/Lifecycle.zig");
    _ = @import("http2/Observer.zig");
    _ = @import("http2/RelayConfiguration.zig");
    _ = @import("http2/RelayOptions.zig");
    _ = @import("http2/RelayRoute.zig");
    _ = @import("http2/RequestBody.zig");
    _ = @import("http2/RequestFinished.zig");
    _ = @import("http2/ResponseBody.zig");
    _ = @import("http2/Stats.zig");
    _ = @import("http2/connection.zig");
    _ = @import("http2/http2.zig");
    _ = @import("http2/relay.zig");
}

//! An HTTP relay that forwards intercepted HTTP/1.1 and HTTP/2 traffic
//! byte for byte while it reports what it forwarded: heads, de-framed body
//! fragments, and HTTP/2 stream stages. Requests matching watched routes are
//! flagged; no rule decides what a request means.

pub const http1 = @import("http1/http1.zig");
pub const http2 = @import("http2/http2.zig");
pub const RouteMatch = @import("RouteMatch.zig");
pub const header_rules = @import("header_rules.zig");
pub const observer_hooks = @import("observer_hooks.zig");

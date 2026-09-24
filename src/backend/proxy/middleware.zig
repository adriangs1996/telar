//! Lifecycle observations the proxy publishes to the runtime: the phase of
//! one request, the protocol it travelled over, and the API dialect of its
//! host.

const types = @import("../agent/types.zig");

pub const Phase = enum {
    request_started,
    auxiliary_request_started,
    response_activity,
    provider_turn_completed,
    response_finished,
    request_failed,
};

pub const Protocol = enum { http11, h2, upgraded };

pub const ApiDialect = types.ApiDialect;

pub const Event = @import("MiddlewareEvent.zig");

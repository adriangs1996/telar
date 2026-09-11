//! Application-facing boundary for starting asynchronous runtime operations.

const std = @import("std");
const client_session = @import("../client/root.zig").session;
const agent_event_dispatcher = @import("event_dispatcher/agent.zig");
const client_event_dispatcher = @import("event_dispatcher/client.zig");
const pane_event_dispatcher = @import("event_dispatcher/pane/root.zig");
const request_dispatch = @import("request_dispatch.zig");

pub const ClientSession = client_session.Session;

pub const Scheduler = @import("GenericScheduler.zig").Type;

test {
    std.testing.refAllDecls(@This());
}

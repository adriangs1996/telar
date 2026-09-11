//! Runtime-event adapter for asynchronous history responses.

const std = @import("std");
const history = @import("../../../history/root.zig");
const client_session = @import("../../client/root.zig").session;
const delivery_mod = @import("../../delivery/root.zig");
const runtime_event_entrypoints = @import("../../entrypoints/events/root.zig");
const event_sources = @import("../../event_sources.zig");

pub const ClientKey = client_session.Key;
pub const ClientSession = client_session.Session;
pub const ResponseQueue = delivery_mod.ResponseQueue;
pub const history_response_controller = runtime_event_entrypoints.history_response;

pub const Dispatcher = @import("GenericHistoryDispatcher.zig").Type;

test {
    std.testing.refAllDecls(@This());
}

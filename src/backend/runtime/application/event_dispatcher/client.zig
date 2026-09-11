//! Runtime-event adapters for client admission, reads and writes.

const std = @import("std");
const core = @import("telar-core");
const client_runtime = @import("../../client/root.zig");
const delivery_mod = @import("../../delivery/root.zig");
const runtime_event = @import("../../event.zig");
const event_sources = @import("../../event_sources.zig");
const transport = @import("../../../transport/root.zig");

pub const Io = std.Io;
pub const schema = core.schema;
pub const diagnostics = core.diagnostics;

pub const client_admission = client_runtime.admission;
pub const client_request_router = client_runtime.request_router;
const client_session = client_runtime.session;
pub const client_send_coordinator = client_runtime.send_coordinator;

pub const ClientKey = client_session.Key;
pub const ClientSession = client_session.Session;
pub const SessionRead = client_session.Read;
pub const SessionWrite = client_session.Write;
pub const ClientMessageEvent = runtime_event.ClientMessage;
pub const ClientSentEvent = runtime_event.ClientSent;

pub const Dispatcher = @import("GenericClientDispatcher.zig").Type;

test {
    std.testing.refAllDecls(@This());
}

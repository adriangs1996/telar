//! Bounded ownership transfer between history producers and the worker.

const core = @import("telar-core");

/// Requests waiting for the history worker. A full queue refuses without
/// blocking: a query is answered `resource_limit`, a recorded command is
/// lost, and both report this limit.
pub const request_capacity = 64;
pub const requests_limit = core.Limit.declare("history.request_queue", "requests", request_capacity);
pub const response_capacity = 4;

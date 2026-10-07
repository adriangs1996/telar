//! Typed continuations for requests sent by the disposable client.
//!
//! The client registers a request and its outbound message as one operation.
//! Exactly one success or failure consumes the continuation. Lifecycle events
//! may turn it into `.ignored` when the runtime already made the result stale.

pub const Continuation = @import("RequestsContinuation.zig").RequestsContinuation;

pub const Group = @import("RequestsGroup.zig").RequestsGroup;

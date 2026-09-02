//! A long-lived headless agent engine owned by the runtime.
//!
//! The engine is Pi in RPC mode, or any command that speaks the same JSONL
//! contract. It answers bounded prompts with bounded text on the observation
//! path: requests queue behind one actor, the child starts on the first
//! prompt, and it is killed after an idle interval or on any protocol failure
//! so the next prompt starts a fresh process. Nothing here touches the
//! interactive path, and prompts never enter process arguments.
//!
//! `types.zig` holds the contract, `service.zig` the actor, `session.zig`
//! one child and its dialogue, and `rpc.zig` the wire codec and framing.

const std = @import("std");
const service = @import("service.zig");
const session = @import("session.zig");
const types = @import("types.zig");

pub const rpc = @import("rpc.zig");

pub const max_prompt_bytes = types.max_prompt_bytes;
pub const max_reply_bytes = types.max_reply_bytes;
pub const max_pending_requests = types.max_pending_requests;

pub const Options = types.Options;
pub const Purpose = types.Purpose;
pub const Prompt = types.Prompt;
pub const Request = types.Request;
pub const Status = types.Status;
pub const Response = types.Response;
pub const Service = service.Service;

test {
    std.testing.refAllDecls(rpc);
    std.testing.refAllDecls(service);
    std.testing.refAllDecls(session);
    std.testing.refAllDecls(types);
}

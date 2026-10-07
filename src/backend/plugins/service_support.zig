//! Runtime tap actor set: one bounded sequential worker per trusted plugin.

const owned = @import("../proxy/capture/owned.zig");
const core = @import("telar-core");
const ServiceSpec = @import("ServiceSpec.zig");
const Exchange = owned.Exchange;
const std = @import("std");

pub const max_workers = 16;
pub const queue_depth = 64;
pub const restart_limit = 5;
pub const restart_window_ms = 10 * 60 * 1000;
/// How long one tap callback may run inside its worker; instructions bound
/// the work and this deadline is the safety net.
pub const callback_deadline_ms = 2 * std.time.ms_per_s;
/// How long the runtime waits for a worker's reply: the callback's deadline
/// plus the time to decode the exchange and write the reply, so a callback
/// that fails at its deadline replies before the runtime gives up.
pub const reply_timeout_ms = callback_deadline_ms + std.time.ms_per_s;
/// Bytes the tap holds together: exchanges waiting in every worker queue
/// and the frames workers are sending. Queued exchanges also stay within
/// the capture quota, so this mostly bounds the frames: four of the
/// largest default exchanges at once.
pub const max_held_bytes = 128 * 1024 * 1024;

pub const queue_depth_limit = core.Limit.declare("plugins.tap.queue_depth", "exchanges", queue_depth);
pub const held_bytes_limit = core.Limit.declare("plugins.tap.max_held_bytes", "bytes", max_held_bytes);
pub const reply_timeout_limit = core.Limit.declare("plugins.tap.reply_timeout_ms", "ms", reply_timeout_ms);
pub const restart_limit_reach = core.Limit.declare("plugins.tap.restart_limit", "restarts in 10 min", restart_limit);

pub fn requireCapability(spec: *const ServiceSpec, capability: core.Capability) !void {
    if (!spec.declared.contains(capability)) {
        return error.CapabilityNotDeclared;
    }
    if (!spec.granted.contains(capability)) {
        return error.CapabilityNotGranted;
    }
}

pub fn capturedBytes(captured: *const Exchange) usize {
    var total: usize = 0;
    inline for (.{ captured.request, captured.response }) |optional| {
        if (optional) |half| {
            total +|= half.head.len +| half.body.len;
        }
    }
    return total;
}

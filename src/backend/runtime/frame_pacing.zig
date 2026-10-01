//! Frame pacing: each attachment sends cell frames at the cadence its client
//! presents at, so a 120 Hz window receives pane output at 120 Hz and a
//! 60 Hz one is not sent frames it would fold away.

const core = @import("telar-core");
const std = @import("std");
const RuntimeModel = @import("RuntimeModel.zig");
const Session = @import("client/Session.zig");

/// Receives a client's frame interval and paces its existing and future
/// attachments to it. The wire refuses an interval outside its bounds; the
/// clamp keeps the same bounds for a message that never crossed it.
///
/// ```zig
/// frame_pacing.configure(model, session, .{ .interval_ns = std.time.ns_per_s / 120 });
/// ```
pub fn configure(model: *RuntimeModel, session: *Session, request: core.ConfigureFrameInterval) void {
    const interval = std.math.clamp(request.interval_ns, core.min_frame_interval_ns, core.max_frame_interval_ns);

    if (session.frame_interval_ns == interval) {
        return;
    }

    session.frame_interval_ns = interval;
    for (&model.attachments.record[session.slot]) |slot| {
        const attachment = slot orelse continue;
        attachment.cell_pacer.interval = interval;
    }
}

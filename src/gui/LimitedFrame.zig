//! The frame that stopped at a limit: what it would show, the viewport it
//! was measured for and the limit it reached. The window does not prepare
//! it again until what it shows or the viewport changes, and its title
//! names the limit meanwhile, since the frame cannot show the notice.
const core = @import("telar-core");
const client = @import("telar-client");
const native = @import("native/native.zig");
const LimitedFrame = @This();

observation: client.Observation,
viewport: native.Viewport,
name: [core.Limit.max_name_bytes]u8 = undefined,
name_len: u8 = 0,

/// Example: `const frame = LimitedFrame.init(observation, viewport, "render.retained_max_cells");`
pub fn init(observation: client.Observation, viewport: native.Viewport, limit_name: []const u8) LimitedFrame {
    var frame: LimitedFrame = .{
        .observation = observation,
        .viewport = viewport,
    };
    const kept = limit_name[0..@min(limit_name.len, frame.name.len)];
    @memcpy(frame.name[0..kept.len], kept);
    frame.name_len = @intCast(kept.len);

    return frame;
}

/// The limit this frame reached. Example: `const name = frame.limitName();`
pub fn limitName(self: *const LimitedFrame) []const u8 {
    return self.name[0..self.name_len];
}

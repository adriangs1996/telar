//! Native drawing cadence and input grace, independent of GPU ownership.
//! Callers supply visible pane identities and only record sealed preparations.
//! The cadence follows the display the window is on.
const std = @import("std");
const pacing = @import("pacing");
const animate = @import("animate");
const data = @import("model");
const core = @import("telar-core");
const PaneInputGrace = @import("PaneInputGrace.zig");
const FrameClock = animate.FrameClock;
const FramePacer = @This();

pub const Pane = data.PresentationCommit.PaneCommit;

const OrdinaryBudget = enum(u32) { frame = 1 };

cadence: pacing.Pacer = .{
    .burst = @intFromEnum(OrdinaryBudget.frame),
    .credits = @intFromEnum(OrdinaryBudget.frame),
},
inputs: [core.max_panes_per_tab]?PaneInputGrace = @splat(null),
/// The refresh interval of the display the window is on, as the native
/// window last reported it.
display_interval_ns: u64 = pacing.pace.default_interval,

/// Paces frames at the display's rate, or slower when `max_fps` caps it,
/// within the cadences the runtime accepts, and returns the interval. The
/// widget animation clock asks for its frames at the same interval. Credit,
/// grace and the cadence anchor carry over, so a window moved to another
/// display keeps its burst and its next deadline stays monotonic.
/// Example: `const interval_ns = pacer.pace(config.max_fps, &gui.chrome.animation);`
pub fn pace(self: *FramePacer, max_fps: ?u16, animation: *FrameClock) u64 {
    const cap: u64 = if (max_fps) |fps| std.time.ns_per_s / @as(u64, @max(fps, 1)) else 0;
    const interval = std.math.clamp(@max(self.display_interval_ns, cap), core.min_frame_interval_ns, core.max_frame_interval_ns);
    self.cadence.interval = interval;
    animation.interval_ns = interval;
    return interval;
}

/// Records admitted input against the pane's current applied frame. Replacing
/// the oldest entry when full drops only grace, never input or pending damage.
/// Example: `pacer.noteInput(current_pane, now_ns);`
pub fn noteInput(self: *FramePacer, pane: Pane, now_ns: u64) void {
    if (!pane.attached or pane.pane_id == .invalid) {
        return;
    }

    var vacant: ?usize = null;
    var oldest: usize = 0;
    for (self.inputs, 0..) |entry, index| {
        const previous = entry orelse {
            if (vacant == null) {
                vacant = index;
            }

            continue;
        };
        if (previous.pane.pane_id == pane.pane_id) {
            if (previous.pane.attachment_generation > pane.attachment_generation or
                now_ns < previous.started_ns or
                (previous.pane.attachment_generation == pane.attachment_generation and previous.pane.frame_id > pane.frame_id))
            {
                return;
            }

            self.inputs[index] = .{ .pane = pane, .started_ns = now_ns };
            return;
        }

        if (self.inputs[oldest]) |first| {
            if (previous.started_ns < first.started_ns) {
                oldest = index;
            }
        } else {
            oldest = index;
        }
    }

    self.inputs[vacant orelse oldest] = .{ .pane = pane, .started_ns = now_ns };
}

/// Returns an absolute deadline without consuming credits or grace. Only
/// visible terminal panes belong in this borrowed candidate slice.
/// Example: `const deadline_ns = pacer.waitUntil(visible_panes, now_ns);`
pub fn waitUntil(self: *const FramePacer, panes: []const Pane, now_ns: u64) ?u64 {
    const ordinary = self.cadence.waitUntil(now_ns) orelse return null;
    for (self.inputs) |entry| {
        const grace = entry orelse continue;
        if (now_ns < grace.started_ns) {
            continue;
        }

        const scoped = grace.scoped(self.cadence);
        if (scoped.waitUntil(now_ns) != null) {
            continue;
        }

        for (panes) |pane| {
            if (grace.includes(pane)) {
                return null;
            }
        }
    }

    return ordinary;
}

/// Records preparation time only after a nonzero presentation token is sealed.
/// GPU failure retains model damage; a retry still follows the remaining budget.
/// A slightly late ordinary frame keeps cadence. After a full missed interval
/// or an early input frame, the next interval starts at preparation time.
/// Example: `pacer.record(flight.delivery.commit.slice(), now_ns);`
pub fn record(self: *FramePacer, panes: []const Pane, now_ns: u64) void {
    const deadline: ?u64 = if (self.cadence.anchor_ns) |anchor| anchor +| self.cadence.interval else null;
    const frame: pacing.Pacer.Record = .{
        .now = now_ns,
        .scheduled_deadline = if (deadline) |due| if (due <= now_ns and now_ns - due < self.cadence.interval) due else null else null,
        .absorbed = 1,
    };
    for (&self.inputs) |*entry| {
        const grace = if (entry.*) |*value| value else continue;
        if (now_ns < grace.started_ns) {
            continue;
        }

        for (panes) |pane| {
            if (!grace.includes(pane)) {
                continue;
            }

            var scoped = grace.scoped(self.cadence);
            if (scoped.waitUntil(now_ns) != null) {
                break;
            }

            scoped.record(frame);
            grace.record(pane, scoped);
            break;
        }
    }

    self.cadence.record(frame);
}

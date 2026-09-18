//! Native drawing cadence and input grace, independent of GPU ownership.
//! Callers supply visible pane identities and only record sealed preparations.
const core = @import("telar-core");
const client = @import("telar-client");
const PaneInputGrace = @import("PaneInputGrace.zig");
const FramePacer = @This();

pub const Pane = client.PresentationCommit.PaneCommit;

const OrdinaryBudget = enum(u32) { frame = 1 };

cadence: core.Pacer = .{
    .burst = @intFromEnum(OrdinaryBudget.frame),
    .credits = @intFromEnum(OrdinaryBudget.frame),
},
inputs: [core.max_panes_per_tab]?PaneInputGrace = @splat(null),

/// Records admitted input against the pane's current applied frame. Replacing
/// the oldest entry when full drops only grace, never input or pending damage.
/// Example: `pacer.noteInput(current_pane, now_ns);`
pub fn noteInput(pacer: *FramePacer, pane: Pane, now_ns: u64) void {
    if (!pane.attached or pane.pane_id == .invalid) {
        return;
    }

    var vacant: ?usize = null;
    var oldest: usize = 0;
    for (pacer.inputs, 0..) |entry, index| {
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

            pacer.inputs[index] = .{ .pane = pane, .started_ns = now_ns };
            return;
        }

        if (pacer.inputs[oldest]) |first| {
            if (previous.started_ns < first.started_ns) {
                oldest = index;
            }
        } else {
            oldest = index;
        }
    }

    pacer.inputs[vacant orelse oldest] = .{ .pane = pane, .started_ns = now_ns };
}

/// Returns an absolute deadline without consuming credits or grace. Only
/// visible terminal panes belong in this borrowed candidate slice.
/// Example: `const deadline_ns = pacer.waitUntil(visible_panes, now_ns);`
pub fn waitUntil(pacer: *const FramePacer, panes: []const Pane, now_ns: u64) ?u64 {
    const ordinary = pacer.cadence.waitUntil(now_ns) orelse return null;
    for (pacer.inputs) |entry| {
        const grace = entry orelse continue;
        if (now_ns < grace.started_ns) {
            continue;
        }

        const scoped = grace.scoped(pacer.cadence);
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
pub fn record(pacer: *FramePacer, panes: []const Pane, now_ns: u64) void {
    const deadline: ?u64 = if (pacer.cadence.anchor_ns) |anchor| anchor +| pacer.cadence.interval else null;
    const frame: core.Pacer.Record = .{
        .now = now_ns,
        .scheduled_deadline = if (deadline) |due| if (due <= now_ns and now_ns - due < pacer.cadence.interval) due else null else null,
        .absorbed = 1,
    };
    for (&pacer.inputs) |*entry| {
        const grace = if (entry.*) |*value| value else continue;
        if (now_ns < grace.started_ns) {
            continue;
        }

        for (panes) |pane| {
            if (!grace.includes(pane)) {
                continue;
            }

            var scoped = grace.scoped(pacer.cadence);
            if (scoped.waitUntil(now_ns) != null) {
                break;
            }

            scoped.record(frame);
            grace.record(pane, scoped);
            break;
        }
    }

    pacer.cadence.record(frame);
}

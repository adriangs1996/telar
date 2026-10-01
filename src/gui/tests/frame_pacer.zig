const pacing = @import("pacing");
const std = @import("std");
const core = @import("telar-core");
const FramePacer = @import("../FramePacer.zig");
const animate = @import("animate");
const FrameClock = animate.FrameClock;

const Instant = enum(u64) {
    initial = 100 * std.time.ns_per_ms,
    input = 101 * std.time.ns_per_ms,
    echo = 102 * std.time.ns_per_ms,
    later = 103 * std.time.ns_per_ms,
};
const Identity = enum(u64) { target = 1, background = 2, replacement = 3 };
const Generation = enum(u64) { initial = 1, replacement = 2 };
const Revision = enum(u64) { initial = 1, pending = 7, echo = 8, following = 9 };
const QueryCount = enum(usize) { repeated = 32 };
const Duration = enum(u64) { tick = 1, late_wakeup = std.time.ns_per_ms };
/// Refresh rates and caps in frames per second.
const Rate = enum(u16) { thirty = 30, sixty = 60, promotion = 120, external = 144, fastest = 240, faster = 360, cinema = 24 };

fn interval(rate: Rate) u64 {
    return std.time.ns_per_s / @as(u64, @intFromEnum(rate));
}

fn now(instant: Instant) u64 {
    return @intFromEnum(instant);
}

fn pane(identity: Identity, revision: Revision) FramePacer.Pane {
    return .{
        .pane_id = @enumFromInt(@intFromEnum(identity)),
        .frame_id = @intFromEnum(revision),
        .attached = true,
        .attachment_generation = @intFromEnum(Generation.initial),
    };
}

fn busy() FramePacer {
    var pacer: FramePacer = .{};
    pacer.record(&.{}, now(.initial));
    return pacer;
}

fn ordinaryDeadline() u64 {
    return now(.initial) + pacing.pace.default_interval;
}

test "native cadence starts immediately and preserves its slot after a late wake" {
    var pacer: FramePacer = .{};
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{}, now(.initial)));
    pacer.record(&.{}, now(.initial));
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{}, now(.echo)));

    const late = ordinaryDeadline() + @intFromEnum(Duration.late_wakeup);
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{}, late));
    pacer.record(&.{}, late);
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline() + pacing.pace.default_interval), pacer.waitUntil(&.{}, late));
}

test "native drawing after idle starts a full interval instead of reusing an old slot" {
    var pacer = busy();
    const resumed = ordinaryDeadline() + pacing.pace.default_interval + @intFromEnum(Duration.late_wakeup);
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{}, resumed));
    pacer.record(&.{}, resumed);
    try std.testing.expectEqual(@as(?u64, resumed + pacing.pace.default_interval), pacer.waitUntil(&.{}, resumed));
    try std.testing.expectEqual(@as(?u64, resumed + pacing.pace.default_interval), pacer.waitUntil(&.{}, resumed + @intFromEnum(Duration.tick)));
}

test "native input grace ignores pre-input damage and output from another pane" {
    var pacer = busy();
    const pending = pane(.target, .pending);
    pacer.noteInput(pending, now(.input));
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{pending}, now(.echo)));
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{pane(.target, .initial)}, now(.echo)));
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{pane(.background, .echo)}, now(.echo)));
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{}, now(.echo)));
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{pane(.target, .echo)}, now(.echo)));
}

test "native admission queries never consume cadence or input grace" {
    var pacer = busy();
    pacer.noteInput(pane(.target, .pending), now(.input));
    const before = pacer;
    for (0..@intFromEnum(QueryCount.repeated)) |_| {
        try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{pane(.target, .echo)}, now(.echo)));
    }

    try std.testing.expectEqualDeep(before, pacer);
}

test "native grace charges a captured revision once and admits its successor" {
    var pacer = busy();
    pacer.noteInput(pane(.target, .pending), now(.input));
    pacer.record(&.{pane(.target, .echo)}, now(.echo));
    const deadline = now(.echo) + pacing.pace.default_interval;
    try std.testing.expectEqual(@as(?u64, deadline), pacer.waitUntil(&.{pane(.target, .echo)}, now(.later)));
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{pane(.target, .following)}, now(.later)));
}

test "native input grace spends only its bounded frame budget and accrues no cadence debt" {
    var pacer = busy();
    var candidate = pane(.target, .pending);
    pacer.noteInput(candidate, now(.input));
    for (0..pacing.pace.default_input_frames) |_| {
        candidate.frame_id += 1;
        try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{candidate}, now(.echo)));
        pacer.record(&.{candidate}, now(.echo));
    }

    candidate.frame_id += 1;
    const deadline = now(.echo) + pacing.pace.default_interval;
    try std.testing.expectEqual(@as(?u64, deadline), pacer.waitUntil(&.{candidate}, now(.echo)));
    try std.testing.expectEqual(@as(u64, pacing.pace.default_input_frames + 1), pacer.cadence.stats.drawn);
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{candidate}, deadline));
    pacer.record(&.{candidate}, deadline);
    try std.testing.expectEqual(@as(?u64, deadline + pacing.pace.default_interval), pacer.waitUntil(&.{candidate}, deadline));
}

test "native grace expires exactly at its deadline and cannot precede input" {
    var pacer = busy();
    pacer.noteInput(pane(.target, .pending), now(.input));
    const candidate = pane(.target, .echo);
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{candidate}, now(.initial)));

    const expiration = now(.input) + pacing.pace.default_input_grace;
    const before = expiration - @intFromEnum(Duration.tick);
    pacer.record(&.{}, before);
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{candidate}, before));
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline() + pacing.pace.default_interval), pacer.waitUntil(&.{candidate}, expiration));
}

test "native preparations charge only panes captured in that commit" {
    var pacer = busy();
    pacer.noteInput(pane(.target, .pending), now(.input));
    pacer.noteInput(pane(.background, .pending), now(.input));
    var target = pane(.target, .pending);
    for (0..pacing.pace.default_input_frames) |_| {
        target.frame_id += 1;
        pacer.record(&.{target}, now(.echo));
    }

    target.frame_id += 1;
    try std.testing.expectEqual(@as(?u64, now(.echo) + pacing.pace.default_interval), pacer.waitUntil(&.{target}, now(.later)));
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{pane(.background, .echo)}, now(.later)));
}

test "native reattachment cannot inherit grace or be replaced by stale input" {
    var pacer = busy();
    pacer.noteInput(pane(.target, .pending), now(.input));
    var replacement = pane(.target, .initial);
    replacement.attachment_generation = @intFromEnum(Generation.replacement);
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{replacement}, now(.echo)));

    pacer.noteInput(replacement, now(.echo));
    pacer.noteInput(pane(.target, .following), now(.later));
    replacement.frame_id += 1;
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{replacement}, now(.later)));
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{pane(.target, .following)}, now(.later)));
}

test "native new input resets grace against the latest applied frame" {
    var pacer = busy();
    var candidate = pane(.target, .pending);
    pacer.noteInput(candidate, now(.input));
    for (0..pacing.pace.default_input_frames) |_| {
        candidate.frame_id += 1;
        pacer.record(&.{candidate}, now(.echo));
    }

    pacer.noteInput(candidate, now(.later));
    try std.testing.expectEqual(@as(?u64, now(.echo) + pacing.pace.default_interval), pacer.waitUntil(&.{candidate}, now(.later)));
    candidate.frame_id += 1;
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{candidate}, now(.later)));
}

test "native grace ignores detached and invalid panes" {
    var pacer = busy();
    var detached = pane(.target, .pending);
    detached.attached = false;
    pacer.noteInput(detached, now(.input));
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{pane(.target, .echo)}, now(.echo)));

    pacer.noteInput(pane(.target, .pending), now(.input));
    detached.frame_id = @intFromEnum(Revision.echo);
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{detached}, now(.echo)));
    var invalid = pane(.background, .pending);
    invalid.pane_id = .invalid;
    pacer.noteInput(invalid, now(.input));
    invalid.frame_id += 1;
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{invalid}, now(.echo)));
}

test "native grace capacity replaces the oldest input without affecting cadence" {
    var pacer = busy();
    for (0..core.max_panes_per_tab) |index| {
        var current = pane(.target, .initial);
        current.pane_id = @enumFromInt(index + @intFromEnum(Identity.target));
        pacer.noteInput(current, now(.input) + index);
    }

    var replacement = pane(.replacement, .initial);
    replacement.pane_id = @enumFromInt(core.max_panes_per_tab + @intFromEnum(Identity.target));
    pacer.noteInput(replacement, now(.input) + core.max_panes_per_tab);
    replacement.frame_id += 1;
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline()), pacer.waitUntil(&.{pane(.target, .pending)}, now(.echo)));
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{pane(.background, .pending)}, now(.echo)));
    try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{replacement}, now(.echo)));
}

test "native ordinary frames do not spend input grace" {
    var pacer = busy();
    var candidate = pane(.target, .pending);
    pacer.noteInput(candidate, now(.input));
    candidate.frame_id += 1;
    pacer.record(&.{candidate}, ordinaryDeadline());
    for (0..pacing.pace.default_input_frames) |_| {
        candidate.frame_id += 1;
        try std.testing.expectEqual(@as(?u64, null), pacer.waitUntil(&.{candidate}, ordinaryDeadline()));
        pacer.record(&.{candidate}, ordinaryDeadline());
    }

    candidate.frame_id += 1;
    try std.testing.expectEqual(@as(?u64, ordinaryDeadline() + pacing.pace.default_interval), pacer.waitUntil(&.{candidate}, ordinaryDeadline()));
}

test "native cadence follows the display under the configured cap and the runtime bounds" {
    var pacer: FramePacer = .{};
    var animation: FrameClock = .{};
    pacer.display_interval_ns = interval(.promotion);
    try std.testing.expectEqual(interval(.promotion), pacer.pace(null, &animation));
    try std.testing.expectEqual(interval(.promotion), pacer.pace(@intFromEnum(Rate.fastest), &animation));
    try std.testing.expectEqual(interval(.sixty), pacer.pace(@intFromEnum(Rate.sixty), &animation));

    pacer.display_interval_ns = interval(.external);
    try std.testing.expectEqual(interval(.external), pacer.pace(null, &animation));
    try std.testing.expectEqual(interval(.external), pacer.cadence.interval);
    try std.testing.expectEqual(interval(.external), animation.interval_ns);

    pacer.display_interval_ns = interval(.faster);
    try std.testing.expectEqual(core.min_frame_interval_ns, pacer.pace(null, &animation));
    pacer.display_interval_ns = interval(.cinema);
    try std.testing.expectEqual(core.max_frame_interval_ns, pacer.pace(null, &animation));
    pacer.display_interval_ns = interval(.sixty);
    try std.testing.expectEqual(interval(.thirty), pacer.pace(@intFromEnum(Rate.thirty), &animation));
}

test "native cadence presents a 120 Hz display's frames one display interval apart" {
    var pacer: FramePacer = .{};
    var animation: FrameClock = .{};
    pacer.display_interval_ns = interval(.promotion);
    _ = pacer.pace(null, &animation);
    pacer.record(&.{}, now(.initial));
    try std.testing.expectEqual(@as(?u64, now(.initial) + interval(.promotion)), pacer.waitUntil(&.{}, now(.echo)));

    const slot = now(.initial) + interval(.promotion);
    pacer.record(&.{}, slot + @intFromEnum(Duration.tick));
    try std.testing.expectEqual(@as(?u64, slot + interval(.promotion)), pacer.waitUntil(&.{}, slot + @intFromEnum(Duration.tick)));
}

//! Runtime sampling and telemetry admission retain their independent budgets.
const std = @import("std");
const RequestFixture = @import("RequestFixture.zig");
const EventFixture = @import("EventFixture.zig");
const Sampler = @import("../observability/Sampler.zig");

test "runtime metric timer and scheduler failures leave sampling admission available" {
    var fixture: EventFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    _ = try fixture.request.runtime.update(.{ .metrics_tick = error.TimerFailed });
    try std.testing.expect(!fixture.model.system_metrics_pending);
    fixture.failScheduling();
    try std.testing.expectError(error.ConcurrencyUnavailable, fixture.request.runtime.update(.{ .metrics_tick = {} }));
    try std.testing.expect(!fixture.model.system_metrics_pending);
}

test "runtime metric completion replaces the owned sample before clearing single-flight state" {
    for ([_]bool{ false, true }) |changed| {
        var fixture: RequestFixture = undefined;
        try fixture.init();
        defer fixture.deinit();
        const model = &fixture.runtime.model;
        model.system_metrics_pending = true;
        var sample: Sampler = model.system_metrics;
        sample.previous_total = 99;
        if (changed) {
            sample.revision += 1;
        }
        _ = try fixture.runtime.update(.{ .metrics_sampled = .{ .sampler = sample, .duration_ns = 37, .captured_ns = 41 } });
        try std.testing.expect(!model.system_metrics_pending);
        try std.testing.expectEqualDeep(sample, model.system_metrics);
        try std.testing.expectEqual(@as(u64, 37), model.metrics.system_sample.total_ns);
        try std.testing.expectEqual(@as(u64, 41), model.metrics.system_sample_last_ns);
    }
}

test "runtime telemetry failure retains a live write until its completion releases the buffer" {
    var fixture: RequestFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    const telemetry = &fixture.runtime.resources.telemetry;
    telemetry.beginWrite();
    _ = try fixture.runtime.update(.{ .telemetry_tick = error.TimerFailed });
    try std.testing.expect(telemetry.writePending());
    try std.testing.expect(!telemetry.available());
    _ = try fixture.runtime.update(.{ .telemetry_written = error.WriteFailed });
    try std.testing.expect(!telemetry.writePending());
    try std.testing.expect(!telemetry.available());
    _ = try fixture.runtime.update(.{ .telemetry_tick = {} });
    try std.testing.expect(!telemetry.writePending());
}

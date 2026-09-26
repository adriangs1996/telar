//! What the built-in metric components say and when they ask for attention.
//! Both adapters format from here, so the TUI and the GUI agree.
const MetricName = @import("MetricName.zig").MetricName;
const SystemMetrics = @import("../state/SystemMetrics.zig");
const Tone = @import("Tone.zig").Tone;
const std = @import("std");

pub const max_value_bytes = 16;

const cpu_warning: u8 = 90;
const cpu_danger: u8 = 98;
const battery_warning: u8 = 20;
const battery_danger: u8 = 10;
const tenths: u16 = 10;

/// Whether the host reports this metric; a host without a battery hides it.
/// Example: `if (!bar_metrics.available(.battery, metrics)) return 0;`
pub fn available(name: MetricName, metrics: ?SystemMetrics) bool {
    const sample = metrics orelse return false;
    return name != .battery or sample.battery_percent != null;
}

/// The short label drawn before the value; the battery draws a shape instead.
pub fn label(name: MetricName) []const u8 {
    return switch (name) {
        .cpu => "CPU",
        .memory => "MEM",
        .battery => "",
    };
}

/// Example: `const text = bar_metrics.value(&buffer, .memory, metrics); // "12.8 GB"`
pub fn value(buffer: *[max_value_bytes]u8, name: MetricName, metrics: ?SystemMetrics) []const u8 {
    const sample = metrics orelse return "";
    return switch (name) {
        .cpu => std.fmt.bufPrint(buffer, "{d}%", .{sample.cpu_percent}) catch "",
        .memory => std.fmt.bufPrint(buffer, "{d}.{d} GB", .{ sample.memory_used_decigib / tenths, sample.memory_used_decigib % tenths }) catch "",
        .battery => if (sample.battery_percent) |battery| std.fmt.bufPrint(buffer, "{d}%", .{battery}) catch "" else "",
    };
}

/// The fraction a metric fills, in percent, for shapes such as the battery.
pub fn percent(name: MetricName, metrics: ?SystemMetrics) u8 {
    const sample = metrics orelse return 0;
    return switch (name) {
        .cpu => sample.cpu_percent,
        .memory => 0,
        .battery => sample.battery_percent orelse 0,
    };
}

/// Example: `const tone = bar_metrics.tone(.cpu, metrics); // .warning at 95%`
pub fn tone(name: MetricName, metrics: ?SystemMetrics) Tone {
    const sample = metrics orelse return .neutral;
    return switch (name) {
        .cpu => if (sample.cpu_percent >= cpu_danger) .danger else if (sample.cpu_percent >= cpu_warning) .warning else .neutral,
        .memory => .neutral,
        .battery => {
            const battery = sample.battery_percent orelse return .neutral;
            return if (battery <= battery_danger) .danger else if (battery <= battery_warning) .warning else .neutral;
        },
    };
}

test "metrics format their values and ask for attention at their thresholds" {
    const metrics: SystemMetrics = .{
        .runtime_revision = 1,
        .cpu_percent = 95,
        .memory_used_decigib = 128,
        .battery_percent = 9,
    };
    var buffer: [max_value_bytes]u8 = undefined;

    try std.testing.expectEqualStrings("12.8 GB", value(&buffer, .memory, metrics));
    try std.testing.expectEqualStrings("9%", value(&buffer, .battery, metrics));
    try std.testing.expectEqual(Tone.warning, tone(.cpu, metrics));
    try std.testing.expectEqual(Tone.danger, tone(.battery, metrics));
    try std.testing.expect(!available(.battery, .{ .runtime_revision = 1, .cpu_percent = 1, .memory_used_decigib = 1, .battery_percent = null }));
}

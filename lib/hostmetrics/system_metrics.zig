//! Host health sampling for the runtime.
//!
//! A single-flight observation actor samples an owned copy. It keeps only
//! the latest values plus the previous cpu tick counters, holds no memory
//! between samples (IOKit's power-source copies are released within one),
//! and bumps a revision only when a value the user can see
//! actually changed, so `pump` stays level-triggered like the agent snapshot.
//!
//! The runtime samples its own host on purpose: a remote client should see
//! the machine the agents run on, not the laptop showing the UI. macOS reads
//! mach host counters from libSystem and the battery from IOKit's power
//! sources; Linux reads procfs and sysfs. A host without a battery reports
//! none.

const std = @import("std");
const Raw = @import("Raw.zig");
const builtin = @import("builtin");
const darwin = @import("darwin.zig");

pub const Values = @import("Values.zig");

pub const Sample = @import("SystemMetricsSample.zig");

/// Samples a value-owned copy without borrowing runtime state.
/// Example: `const result = sampleOwned(io, previous);`.
pub fn sampleOwned(io: std.Io, previous: Sampler) Sample {
    const started = std.Io.Clock.awake.now(io).nanoseconds;
    var sampler = previous;
    sampler.sample();
    const finished = std.Io.Clock.awake.now(io).nanoseconds;
    return .{ .sampler = sampler, .duration_ns = @intCast(finished - started), .captured_ns = @intCast(finished) };
}

pub const Sampler = @import("Sampler.zig");

pub fn cpuPercent(previous: CpuTicks, current: CpuTicks) u8 {
    if (previous.total == 0) {
        return 0;
    }

    const busy_delta = current.busy -| previous.busy;
    const total_delta = current.total -| previous.total;

    if (total_delta == 0) {
        return 0;
    }

    return @intCast(@min(100, busy_delta * 100 / total_delta));
}

pub fn decigib(bytes: u64) u16 {
    const tenths = bytes * 10 / (1024 * 1024 * 1024);
    return @intCast(@min(tenths, std.math.maxInt(u16)));
}

fn cpuCount() u16 {
    const count = std.Thread.getCpuCount() catch return 0;
    return @intCast(@min(count, std.math.maxInt(u16)));
}

pub fn readRaw() ?Raw {
    return switch (builtin.os.tag) {
        .macos => readDarwin(),
        .linux => readLinux(),
        else => null,
    };
}

// -- macOS ------------------------------------------------------------------

fn readDarwin() ?Raw {
    if (builtin.os.tag != .macos) {
        return null;
    }
    const host = darwin.mach_host_self();

    var cpu: [darwin.cpu_load_words]u32 = undefined;
    var cpu_count: u32 = darwin.cpu_load_words;
    if (darwin.host_statistics64(host, darwin.HOST_CPU_LOAD_INFO, &cpu, &cpu_count) != 0) {
        return null;
    }
    const user: u64 = cpu[0];
    const system: u64 = cpu[1];
    const idle: u64 = cpu[2];
    const nice: u64 = cpu[3];

    var vm: [darwin.vm_info_words]u32 = undefined;
    var vm_count: u32 = darwin.vm_info_words;
    if (darwin.host_statistics64(host, darwin.HOST_VM_INFO64, &vm, &vm_count) != 0) {
        return null;
    }
    const page_size: u64 = @intCast(darwin.getpagesize());
    const used_pages: u64 = @as(u64, vm[darwin.vm_active_word]) +
        vm[darwin.vm_wire_word] + vm[darwin.vm_compressor_word];

    return .{
        .busy_ticks = user + system + nice,
        .total_ticks = user + system + nice + idle,
        .memory_used_bytes = used_pages * page_size,
        .memory_total_bytes = std.process.totalSystemMemory() catch 0,
        .cpu_count = cpuCount(),
        .battery_percent = readDarwinBattery(),
    };
}

/// The first power source that reports a capacity, as a percentage of its
/// maximum. Desktops list none.
fn readDarwinBattery() ?u8 {
    if (builtin.os.tag != .macos) {
        return null;
    }

    const blob = darwin.IOPSCopyPowerSourcesInfo() orelse return null;
    defer darwin.CFRelease(blob);
    const sources = darwin.IOPSCopyPowerSourcesList(blob) orelse return null;
    defer darwin.CFRelease(sources);

    const current_key = darwin.__CFStringMakeConstantString(darwin.kIOPSCurrentCapacityKey);
    const max_key = darwin.__CFStringMakeConstantString(darwin.kIOPSMaxCapacityKey);
    const count = darwin.CFArrayGetCount(sources);
    var index: isize = 0;
    while (index < count) : (index += 1) {
        // Descriptions belong to `blob`; they are not released separately.
        const description = darwin.IOPSGetPowerSourceDescription(blob, darwin.CFArrayGetValueAtIndex(sources, index)) orelse continue;
        const current = darwinInteger(darwin.CFDictionaryGetValue(description, current_key)) orelse continue;
        const maximum = darwinInteger(darwin.CFDictionaryGetValue(description, max_key)) orelse continue;
        if (maximum <= 0 or current < 0) {
            continue;
        }

        return @intCast(@min(100, @divTrunc(current * 100, maximum)));
    }

    return null;
}

fn darwinInteger(number: darwin.CFTypeRef) ?i32 {
    const value = number orelse return null;
    var result: i32 = 0;
    if (darwin.CFNumberGetValue(value, darwin.kCFNumberIntType, &result) == 0) {
        return null;
    }

    return result;
}

// -- Linux ------------------------------------------------------------------

fn readLinux() ?Raw {
    var stat_buffer: [512]u8 = undefined;
    const stat = readSmallFile("/proc/stat", &stat_buffer) orelse return null;
    const cpu_line = firstLine(stat);
    var ticks: [8]u64 = @splat(0);
    var iterator = std.mem.tokenizeScalar(u8, cpu_line, ' ');
    _ = iterator.next(); // "cpu"
    for (&ticks) |*tick| {
        const token = iterator.next() orelse break;
        tick.* = std.fmt.parseInt(u64, token, 10) catch return null;
    }
    var total: u64 = 0;
    for (ticks) |tick| total += tick;
    const idle = ticks[3] + ticks[4];

    var meminfo_buffer: [2048]u8 = undefined;
    const meminfo = readSmallFile("/proc/meminfo", &meminfo_buffer) orelse return null;
    const total_kb = meminfoValue(meminfo, "MemTotal:") orelse return null;
    const available_kb = meminfoValue(meminfo, "MemAvailable:") orelse return null;
    const used_kb = total_kb -| available_kb;

    return .{
        .busy_ticks = total - idle,
        .total_ticks = total,
        .memory_used_bytes = used_kb * 1024,
        .memory_total_bytes = total_kb * 1024,
        .cpu_count = cpuCount(),
        .battery_percent = readLinuxBattery(),
    };
}

fn readLinuxBattery() ?u8 {
    const names = [_][]const u8{
        "/sys/class/power_supply/BAT0/capacity",
        "/sys/class/power_supply/BAT1/capacity",
    };
    for (names) |name| {
        var buffer: [16]u8 = undefined;
        const content = readSmallFile(name, &buffer) orelse continue;
        const trimmed = std.mem.trim(u8, content, " \n\t");
        const value = std.fmt.parseInt(u8, trimmed, 10) catch continue;
        return @min(value, 100);
    }
    return null;
}

fn readSmallFile(path: []const u8, buffer: []u8) ?[]const u8 {
    const file = std.posix.openat(std.posix.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0) catch return null;
    defer _ = std.posix.system.close(file);

    const read = std.posix.read(file, buffer) catch return null;
    return buffer[0..read];
}

fn firstLine(content: []const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, content, '\n') orelse content.len;
    return content[0..end];
}

fn meminfoValue(content: []const u8, key: []const u8) ?u64 {
    var lines = std.mem.tokenizeScalar(u8, content, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, key)) {
            continue;
        }
        var tokens = std.mem.tokenizeScalar(u8, line[key.len..], ' ');
        const value = tokens.next() orelse return null;
        return std.fmt.parseInt(u64, value, 10) catch null;
    }
    return null;
}

test "Linux system metrics read the live proc filesystem" {
    if (builtin.os.tag != .linux) {
        return error.SkipZigTest;
    }

    const raw = readLinux() orelse return error.SystemMetricsUnavailable;
    try std.testing.expect(raw.total_ticks > 0);
    try std.testing.expect(raw.busy_ticks <= raw.total_ticks);
    try std.testing.expect(raw.memory_used_bytes > 0);
}

test "macOS system metrics read mach counters and a bounded battery" {
    if (builtin.os.tag != .macos) {
        return error.SkipZigTest;
    }

    const raw = readDarwin() orelse return error.SystemMetricsUnavailable;
    try std.testing.expect(raw.total_ticks > 0);
    try std.testing.expect(raw.memory_used_bytes > 0);
    // A desktop reports no battery; a laptop reports a percentage.
    if (raw.battery_percent) |battery| {
        try std.testing.expect(battery <= 100);
    }
}

test "cpu percentage comes from tick deltas, never the since-boot average" {
    try std.testing.expectEqual(@as(u8, 0), cpuPercent(.{ .busy = 0, .total = 0 }, .{ .busy = 900, .total = 1000 }));
    try std.testing.expectEqual(@as(u8, 50), cpuPercent(.{ .busy = 900, .total = 1000 }, .{ .busy = 950, .total = 1100 }));
    try std.testing.expectEqual(@as(u8, 0), cpuPercent(.{ .busy = 900, .total = 1000 }, .{ .busy = 900, .total = 1000 }));
    try std.testing.expectEqual(@as(u8, 100), cpuPercent(.{ .busy = 0, .total = 1 }, .{ .busy = 5000, .total = 2001 }));
}

test "memory converts to tenths of a GiB" {
    try std.testing.expectEqual(@as(u16, 92), decigib(9 * 1024 * 1024 * 1024 + 205 * 1024 * 1024));
    try std.testing.expectEqual(@as(u16, 0), decigib(50 * 1024 * 1024));
}

test "the revision moves only when a visible value changes" {
    var sampler: Sampler = .{};
    sampler.apply(.{
        .busy_ticks = 100,
        .total_ticks = 1000,
        .memory_used_bytes = 8 * 1024 * 1024 * 1024,
        .memory_total_bytes = 16 * 1024 * 1024 * 1024,
        .cpu_count = 8,
        .battery_percent = 80,
    });
    const first = sampler.revision;
    try std.testing.expect(sampler.latest != null);

    // Same visible values: ticks moved uniformly, memory and battery did not.
    sampler.apply(.{
        .busy_ticks = 100,
        .total_ticks = 1000,
        .memory_used_bytes = 8 * 1024 * 1024 * 1024,
        .memory_total_bytes = 16 * 1024 * 1024 * 1024,
        .cpu_count = 8,
        .battery_percent = 80,
    });
    try std.testing.expectEqual(first, sampler.revision);

    sampler.apply(.{
        .busy_ticks = 600,
        .total_ticks = 2000,
        .memory_used_bytes = 8 * 1024 * 1024 * 1024,
        .memory_total_bytes = 16 * 1024 * 1024 * 1024,
        .cpu_count = 8,
        .battery_percent = 80,
    });
    try std.testing.expect(sampler.revision != first);
    try std.testing.expectEqual(@as(u8, 50), sampler.latest.?.cpu_percent);
}

const CpuTicks = struct {
    /// The first read has no predecessor, so it reports zero instead of a
    /// since-boot average that would spike the bar on startup.
    busy: u64,
    total: u64,
};

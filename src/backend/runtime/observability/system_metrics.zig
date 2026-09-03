//! Host health sampling for the runtime.
//!
//! The sampler runs on the runtime's metrics tick, well off the interactive
//! path. It keeps only the latest values plus the previous cpu tick counters,
//! allocates nothing, and bumps a revision only when a value the user can see
//! actually changed, so `pump` stays level-triggered like the agent snapshot.
//!
//! The runtime samples its own host on purpose: a remote client should see
//! the machine the agents run on, not the laptop showing the UI. macOS reads
//! mach host counters from libSystem; battery needs IOKit, which would add a
//! framework dependency to a build that deliberately needs only a Zig
//! compiler, so macOS reports no battery for now. Linux reads procfs and
//! sysfs, battery included.

const std = @import("std");
const builtin = @import("builtin");

pub const Values = struct {
    cpu_percent: u8,
    memory_used_decigib: u16,
    battery_percent: ?u8,
};

/// Raw counters one platform read produces. Cpu ticks are cumulative since
/// boot; the sampler turns consecutive reads into a percentage.
const Raw = struct {
    busy_ticks: u64,
    total_ticks: u64,
    memory_used_bytes: u64,
    battery_percent: ?u8,
};

pub const Sampler = struct {
    revision: u64 = 1,
    latest: ?Values = null,
    previous_busy: u64 = 0,
    previous_total: u64 = 0,

    /// Reads the current host counters and retains the previous projection when
    /// the platform cannot provide a complete sample. The revision changes
    /// only when the values visible to clients change.
    ///
    /// ```zig
    /// sampler.sample();
    /// ```
    pub fn sample(sampler: *Sampler) void {
        const raw = readRaw() orelse return;
        sampler.apply(raw);
    }

    fn apply(sampler: *Sampler, raw: Raw) void {
        const cpu = cpuPercent(
            .{ .busy = sampler.previous_busy, .total = sampler.previous_total },
            .{ .busy = raw.busy_ticks, .total = raw.total_ticks },
        );
        sampler.previous_busy = raw.busy_ticks;
        sampler.previous_total = raw.total_ticks;
        const next: Values = .{
            .cpu_percent = cpu,
            .memory_used_decigib = decigib(raw.memory_used_bytes),
            .battery_percent = raw.battery_percent,
        };
        if (sampler.latest) |current| {
            if (std.meta.eql(current, next)) {
                return;
            }
        }
        sampler.latest = next;
        sampler.revision +%= 1;
        if (sampler.revision == 0) {
            sampler.revision = 1;
        }
    }
};

/// The first read has no predecessor, so it reports zero instead of a
/// since-boot average that would spike the bar on startup.
const CpuTicks = struct {
    busy: u64,
    total: u64,
};

fn cpuPercent(previous: CpuTicks, current: CpuTicks) u8 {
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

fn decigib(bytes: u64) u16 {
    const tenths = bytes * 10 / (1024 * 1024 * 1024);
    return @intCast(@min(tenths, std.math.maxInt(u16)));
}

fn readRaw() ?Raw {
    return switch (builtin.os.tag) {
        .macos => readDarwin(),
        .linux => readLinux(),
        else => null,
    };
}

// -- macOS ------------------------------------------------------------------

const darwin = struct {
    // These declarations must match the Darwin C ABI exactly.
    extern "c" fn mach_host_self() std.c.mach_port_t;
    extern "c" fn host_statistics64(host: std.c.mach_port_t, flavor: c_int, info: [*]u32, count: *u32) c_int;
    extern "c" fn getpagesize() c_int;

    const HOST_CPU_LOAD_INFO: c_int = 3;
    const HOST_VM_INFO64: c_int = 4;
    const cpu_load_words = 4;
    const vm_info_words = 38;
    // Word offsets into `vm_statistics64`: four natural_t counters first,
    // u64 fields take two words each. Only the ones used below are named.
    const vm_active_word = 1;
    const vm_wire_word = 3;
    const vm_compressor_word = 32;
};

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
        .battery_percent = null,
    };
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
    const file = std.fs.openFileAbsolute(path, .{}) catch return null;
    defer file.close();
    const read = file.read(buffer) catch return null;
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
        .battery_percent = 80,
    });
    const first = sampler.revision;
    try std.testing.expect(sampler.latest != null);

    // Same visible values: ticks moved uniformly, memory and battery did not.
    sampler.apply(.{
        .busy_ticks = 100,
        .total_ticks = 1000,
        .memory_used_bytes = 8 * 1024 * 1024 * 1024,
        .battery_percent = 80,
    });
    try std.testing.expectEqual(first, sampler.revision);

    sampler.apply(.{
        .busy_ticks = 600,
        .total_ticks = 2000,
        .memory_used_bytes = 8 * 1024 * 1024 * 1024,
        .battery_percent = 80,
    });
    try std.testing.expect(sampler.revision != first);
    try std.testing.expectEqual(@as(u8, 50), sampler.latest.?.cpu_percent);
}

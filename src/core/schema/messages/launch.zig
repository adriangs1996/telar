//! The launch body shared by every message that starts a child: cwd,
//! arguments and environment, bounded before any consumer allocates.

const std = @import("std");
const wire = @import("../wire.zig");
const id = @import("../id.zig");
const types = @import("../types.zig");
const codec = @import("../codec.zig");

const PaneId = id.PaneId;
const Launch = types.Launch;
const EnvironmentMode = types.EnvironmentMode;
const EnvironmentEntry = types.EnvironmentEntry;
const validateBytes = codec.validateBytes;
const validatePaneId = codec.validatePaneId;
const validateEnvironmentEntry = codec.validateEnvironmentEntry;

pub const LaunchView = struct {
    cwd: []const u8,
    cwd_source: ?PaneId = null,
    argument_count: u16,
    encoded_arguments: []const u8,
    environment_mode: EnvironmentMode,
    environment_count: u16,
    encoded_environment: []const u8,

    pub fn arguments(launch: LaunchView) ArgumentIterator {
        return .{
            .decoder = .init(launch.encoded_arguments),
            .remaining = launch.argument_count,
        };
    }

    pub fn environment(launch: LaunchView) EnvironmentIterator {
        return .{
            .decoder = .init(launch.encoded_environment),
            .remaining = launch.environment_count,
        };
    }
};

pub const ArgumentIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,
    index: u16 = 0,

    pub fn next(iterator: *ArgumentIterator) !?[]const u8 {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        defer iterator.index += 1;
        const argument = try iterator.decoder.readSized16();
        try validateBytes(argument, std.math.maxInt(u16), iterator.index != 0);
        return argument;
    }
};

pub const EnvironmentIterator = struct {
    decoder: wire.Decoder,
    remaining: u16,

    pub fn next(iterator: *EnvironmentIterator) !?EnvironmentEntry {
        if (iterator.remaining == 0) return null;
        iterator.remaining -= 1;
        const entry: EnvironmentEntry = .{
            .name = try iterator.decoder.readSized16(),
            .value = try iterator.decoder.readSized32(),
        };
        try validateEnvironmentEntry(entry);
        return entry;
    }
};

pub fn encodeLaunch(encoder: *wire.Encoder, launch: Launch) !void {
    try validateBytes(launch.cwd, types.max_cwd_bytes, false);
    if (launch.cwd_source) |pane_id| try validatePaneId(pane_id);
    if (launch.arguments.len == 0 or launch.arguments.len > types.max_argument_count)
        return error.InvalidArgumentCount;
    if (launch.environment.len > types.max_environment_count)
        return error.TooManyEnvironmentEntries;

    try encoder.writeSized16(launch.cwd);
    try encoder.writeInt(u64, if (launch.cwd_source) |pane_id| id.raw(pane_id) else 0);
    try encoder.writeInt(u16, @intCast(launch.arguments.len));
    var argument_bytes: usize = 0;
    for (launch.arguments, 0..) |argument, index| {
        try validateBytes(argument, std.math.maxInt(u16), index != 0);
        argument_bytes = std.math.add(usize, argument_bytes, argument.len) catch
            return error.ArgumentsTooLarge;
        if (argument_bytes > types.max_argument_bytes) return error.ArgumentsTooLarge;
        try encoder.writeSized16(argument);
    }

    try encoder.writeByte(@intFromEnum(launch.environment_mode));
    try encoder.writeInt(u16, @intCast(launch.environment.len));
    var environment_bytes: usize = 0;
    for (launch.environment) |entry| {
        try validateEnvironmentEntry(entry);
        environment_bytes = std.math.add(usize, environment_bytes, entry.name.len) catch
            return error.EnvironmentTooLarge;
        environment_bytes = std.math.add(usize, environment_bytes, entry.value.len) catch
            return error.EnvironmentTooLarge;
        if (environment_bytes > types.max_environment_bytes) return error.EnvironmentTooLarge;
        try encoder.writeSized16(entry.name);
        try encoder.writeSized32(entry.value);
    }
}

pub fn decodeLaunch(decoder: *wire.Decoder) !LaunchView {
    // Structural walk only: field boundaries and byte budgets, so every wire
    // length is checked before a consumer allocates from it. Content rules
    // (embedded NULs, '=' in names) are enforced by the iterators as the
    // consumer decodes each item, so items are only scanned once.
    const cwd = try decoder.readSized16();
    try validateBytes(cwd, types.max_cwd_bytes, false);
    const cwd_source_raw = try decoder.readInt(u64);
    const cwd_source = if (cwd_source_raw == 0)
        null
    else
        try id.pane(cwd_source_raw);

    const argument_count = try decoder.readInt(u16);
    if (argument_count == 0 or argument_count > types.max_argument_count)
        return error.InvalidArgumentCount;
    const arguments_start = decoder.index;
    var argument_bytes: usize = 0;
    for (0..argument_count) |_| {
        const argument = try decoder.readSized16();
        argument_bytes += argument.len;
        if (argument_bytes > types.max_argument_bytes) return error.ArgumentsTooLarge;
    }
    const encoded_arguments = decoder.consumed(arguments_start);

    const environment_mode = try codec.decodeEnvironmentMode(try decoder.readByte());
    const environment_count = try decoder.readInt(u16);
    if (environment_count > types.max_environment_count) return error.TooManyEnvironmentEntries;
    const environment_start = decoder.index;
    var environment_bytes: usize = 0;
    for (0..environment_count) |_| {
        environment_bytes += (try decoder.readSized16()).len;
        environment_bytes += (try decoder.readSized32()).len;
        if (environment_bytes > types.max_environment_bytes) return error.EnvironmentTooLarge;
    }
    return .{
        .cwd = cwd,
        .cwd_source = cwd_source,
        .argument_count = argument_count,
        .encoded_arguments = encoded_arguments,
        .environment_mode = environment_mode,
        .environment_count = environment_count,
        .encoded_environment = decoder.consumed(environment_start),
    };
}

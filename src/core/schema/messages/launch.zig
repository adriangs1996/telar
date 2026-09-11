//! The launch body shared by every message that starts a child: cwd,
//! arguments and environment, bounded before any consumer allocates.

const EncoderType = @import("../Encoder.zig");
const Launch = @import("../Launch.zig");
const codec = @import("../codec.zig");
const types = @import("../types.zig");
const id = @import("../id.zig");
const std = @import("std");
const DecoderType = @import("../Decoder.zig");
const LaunchView = @import("LaunchView.zig");

pub fn encodeLaunch(encoder: *EncoderType, launch: Launch) !void {
    try codec.validateBytes(launch.cwd, types.max_cwd_bytes, false);
    if (launch.cwd_source) |pane_id| {
        try codec.validatePaneId(pane_id);
    }
    if (launch.arguments.len == 0 or launch.arguments.len > types.max_argument_count) {
        return error.InvalidArgumentCount;
    }
    if (launch.environment.len > types.max_environment_count) {
        return error.TooManyEnvironmentEntries;
    }

    try encoder.writeSized16(launch.cwd);
    try encoder.writeInt(u64, if (launch.cwd_source) |pane_id| id.raw(pane_id) else 0);
    try encoder.writeInt(u16, @intCast(launch.arguments.len));
    var argument_bytes: usize = 0;
    for (launch.arguments, 0..) |argument, index| {
        try codec.validateBytes(argument, std.math.maxInt(u16), index != 0);
        argument_bytes = std.math.add(usize, argument_bytes, argument.len) catch
            return error.ArgumentsTooLarge;
        if (argument_bytes > types.max_argument_bytes) {
            return error.ArgumentsTooLarge;
        }
        try encoder.writeSized16(argument);
    }

    try encoder.writeByte(@intFromEnum(launch.environment_mode));
    try encoder.writeInt(u16, @intCast(launch.environment.len));
    var environment_bytes: usize = 0;
    for (launch.environment) |entry| {
        try codec.validateEnvironmentEntry(entry);
        environment_bytes = std.math.add(usize, environment_bytes, entry.name.len) catch
            return error.EnvironmentTooLarge;
        environment_bytes = std.math.add(usize, environment_bytes, entry.value.len) catch
            return error.EnvironmentTooLarge;
        if (environment_bytes > types.max_environment_bytes) {
            return error.EnvironmentTooLarge;
        }
        try encoder.writeSized16(entry.name);
        try encoder.writeSized32(entry.value);
    }
}

pub fn decodeLaunch(decoder: *DecoderType) !LaunchView {
    // Structural walk only: field boundaries and byte budgets, so every wire
    // length is checked before a consumer allocates from it. Content rules
    // (embedded NULs, '=' in names) are enforced by the iterators as the
    // consumer decodes each item, so items are only scanned once.
    const cwd = try decoder.readSized16();
    try codec.validateBytes(cwd, types.max_cwd_bytes, false);
    const cwd_source_raw = try decoder.readInt(u64);
    const cwd_source = if (cwd_source_raw == 0)
        null
    else
        try id.pane(cwd_source_raw);

    const argument_count = try decoder.readInt(u16);
    if (argument_count == 0 or argument_count > types.max_argument_count) {
        return error.InvalidArgumentCount;
    }
    const arguments_start = decoder.index;
    var argument_bytes: usize = 0;
    for (0..argument_count) |_| {
        const argument = try decoder.readSized16();
        argument_bytes += argument.len;
        if (argument_bytes > types.max_argument_bytes) {
            return error.ArgumentsTooLarge;
        }
    }
    const encoded_arguments = decoder.consumed(arguments_start);

    const environment_mode = try codec.decodeEnvironmentMode(try decoder.readByte());
    const environment_count = try decoder.readInt(u16);
    if (environment_count > types.max_environment_count) {
        return error.TooManyEnvironmentEntries;
    }
    const environment_start = decoder.index;
    var environment_bytes: usize = 0;
    for (0..environment_count) |_| {
        environment_bytes += (try decoder.readSized16()).len;
        environment_bytes += (try decoder.readSized32()).len;
        if (environment_bytes > types.max_environment_bytes) {
            return error.EnvironmentTooLarge;
        }
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

//! `telar machine …`: add, rename, enable, disable, remove, list and check
//! the saved machines in `machines.json`, and set one up. Every change holds the file's lock,
//! then replaces it atomically; open windows follow it through their watch.
//! Removing or disabling a machine never touches its runtime.
const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const MachineOptions = @import("arguments/MachineOptions.zig");
const control = @import("control.zig");
const machine_setup = @import("machine_setup.zig");
const config_receive = @import("config_receive.zig");
const remote = client.remote;
const profile_file = client.profile_file;
const machine_profiles = client.machine_profiles;

/// Exit status of a command that failed.
const failure: u8 = 1;
/// The most of SSH's error output a failed check prints, in bytes.
const detail_bytes = 1024;

/// Runs one `telar machine` action and returns its exit status.
///
/// ```zig
/// const status = try machine_profiles.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: MachineOptions) !u8 {
    if (options.action == .receive_config) {
        return config_receive.run(init);
    }

    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try profile_file.path(init.minimal.environ, &path_buffer);
    const profiles = profile_file.load(init.io, init.gpa, path) catch |err| return report(init, err);

    switch (options.action) {
        .setup => return machine_setup.run(init, options),
        .receive_config => unreachable,
        .list => return list(init, &profiles, options.json),
        .check => {
            const row = profiles.find(std.mem.span(options.label.?)) orelse return report(init, error.UnknownMachine);
            return check(init, &profiles.rows[row], options.json);
        },
        .add => {
            // Refuses a bad field before the check, which can take seconds;
            // the change itself is made again under the file's lock.
            const profile = machine_profiles.newProfile(init.io, &profiles, .{
                .label = std.mem.span(options.label.?),
                .destination = std.mem.span(options.value.?),
                .color = if (options.color) |color| std.mem.span(color) else null,
                .enabled = !options.disabled,
            }) catch |err| return report(init, err);

            if (options.check) {
                const status = try check(init, &profile, options.json);
                if (status != 0) {
                    return status;
                }
            }
        },
        .remove, .rename, .enable, .disable => {},
    }

    machine_profiles.store(init.io, init.gpa, path, .{
        .kind = switch (options.action) {
            .add => .add,
            .remove => .remove,
            .rename => .rename,
            .enable => .enable,
            .disable => .disable,
            .list, .check, .setup, .receive_config => unreachable,
        },
        .label = std.mem.span(options.label.?),
        .value = if (options.value) |value| std.mem.span(value) else "",
        .color = if (options.color) |color| std.mem.span(color) else null,
        .enabled = !options.disabled,
    }) catch |err| return report(init, err);

    if (options.action == .add and options.setup) {
        return machine_setup.run(init, options);
    }

    return 0;
}

fn list(init: std.process.Init, profiles: *const core.MachineProfiles, json: bool) !u8 {
    var buffer: [core.MachineProfiles.max_file_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;
    var local_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const local = profile_file.localLabel(profiles, &local_buffer);

    if (json) {
        try writer.writeAll("{\"local\":");
        try control.writeJsonString(writer, local);
        try writer.writeAll(",\"machines\":[");
        for (profiles.slice(), 0..) |*profile, index| {
            if (index != 0) {
                try writer.writeByte(',');
            }

            try core.MachineProfiles.writeProfileJson(writer, profile);
        }

        try writer.writeAll("]}\n");
    } else {
        try writer.print("{s}\tlocal\n", .{local});
        for (profiles.slice()) |*profile| {
            try writer.print("{s}\t{s}\t{s}", .{
                profile.label(),
                profile.destination(),
                if (profile.enabled) "enabled" else "disabled",
            });

            if (profile.color()) |color| {
                try writer.print("\t{s}", .{color});
            }

            try writer.writeByte('\n');
        }
    }

    try writer.flush();
    return 0;
}

fn check(init: std.process.Init, profile: *const core.MachineProfile, json: bool) !u8 {
    var buffer: [4 * std.fs.max_path_bytes]u8 = undefined;
    var output = std.Io.File.stdout().writerStreaming(init.io, &buffer);
    const writer = &output.interface;

    var detail_buffer: [detail_bytes]u8 = undefined;
    var detail: std.Io.Writer = .fixed(&detail_buffer);
    const found = remote.discover(init.io, init.gpa, init.minimal.environ, .{
        .destination = profile.destination(),
        .telar_path = profile.telarPath(),
    }, &detail) catch |err| {
        if (json) {
            try writer.writeAll("{\"label\":");
            try control.writeJsonString(writer, profile.label());
            try writer.print(",\"reachable\":false,\"error\":\"{s}\",\"detail\":", .{@errorName(err)});
            try control.writeJsonString(writer, std.mem.trim(u8, detail.buffered(), " \t\r\n"));
            try writer.writeAll("}\n");
            try writer.flush();
        } else {
            std.debug.print("telar machine: {s} ({s}) is not reachable: {s}\n{s}\n", .{
                profile.label(),
                profile.destination(),
                @errorName(err),
                std.mem.trim(u8, detail.buffered(), " \t\r\n"),
            });
        }

        return failure;
    };

    const defaults = found.launchDefaults();
    const compatible = found.compatible();
    const schema_text: []const u8 = &found.schema;

    if (json) {
        try writer.writeAll("{\"label\":");
        try control.writeJsonString(writer, profile.label());
        try writer.print(",\"reachable\":true,\"schema\":\"{s}\",\"local_schema\":\"{s}\",\"compatible\":{},\"home\":", .{
            schema_text,
            &core.schema_id,
            compatible,
        });
        try control.writeJsonString(writer, defaults.cwd);
        try writer.writeAll(",\"shell\":");
        try control.writeJsonString(writer, defaults.shell);
        try writer.writeAll(",\"socket\":");
        try control.writeJsonString(writer, found.endpoint());
        try writer.writeAll("}\n");
    } else {
        try writer.print("{s}\t{s}\treachable\n  home\t{s}\n  shell\t{s}\n  socket\t{s}\n  schema\t{s} ({s})\n", .{
            profile.label(),
            profile.destination(),
            defaults.cwd,
            defaults.shell,
            found.endpoint(),
            schema_text,
            if (compatible) "matches this telar" else "does not match this telar " ++ core.schema_id ++ "; update telar on one side",
        });
    }

    try writer.flush();
    return if (compatible) 0 else failure;
}

fn report(init: std.process.Init, err: anyerror) u8 {
    const detail = machine_profiles.describe(err);

    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "telar machine: {s}\n", .{detail}) catch return failure;
    std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
    return failure;
}

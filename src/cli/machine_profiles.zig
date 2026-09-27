//! `telar machine …`: add, rename, enable, disable, remove, list and check
//! the saved machines in `machines.json`. Every change replaces the file
//! atomically; open windows follow it through their configuration watch.
//! Removing or disabling a machine never touches its runtime.
const client = @import("telar-client");
const core = @import("telar-core");
const std = @import("std");
const MachineOptions = @import("arguments/MachineOptions.zig");
const control = @import("control.zig");
const remote = client.remote;
const profile_file = client.profile_file;

/// Exit status of a command that failed.
const failure: u8 = 1;

/// Runs one `telar machine` action and returns its exit status.
///
/// ```zig
/// const status = try machine_profiles.run(process_init, options);
/// ```
pub fn run(init: std.process.Init, options: MachineOptions) !u8 {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try profile_file.path(init.minimal.environ, &path_buffer);
    var profiles = profile_file.load(init.io, init.gpa, path) catch |err| return report(init, err);

    switch (options.action) {
        .list => return list(init, &profiles, options.json),
        .check => {
            const row = profiles.find(std.mem.span(options.label.?)) orelse return report(init, error.UnknownMachine);
            return check(init, &profiles.rows[row], options.json);
        },
        .add => {
            var label_buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
            const label = std.mem.span(options.label.?);
            if (std.mem.eql(u8, label, profile_file.localLabel(&profiles, &label_buffer))) {
                return report(init, error.DuplicateMachineLabel);
            }

            const profile = core.MachineProfile.init(try core.MachineId.generate(init.io), .{
                .label = label,
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

            profiles.add(profile) catch |err| return report(init, err);
        },
        .remove => profiles.remove(std.mem.span(options.label.?)) catch |err| return report(init, err),
        .rename => profiles.rename(std.mem.span(options.label.?), std.mem.span(options.value.?)) catch |err| return report(init, err),
        .enable => profiles.enable(std.mem.span(options.label.?), true) catch |err| return report(init, err),
        .disable => profiles.enable(std.mem.span(options.label.?), false) catch |err| return report(init, err),
    }

    try profile_file.save(init.io, path, &profiles);
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

    const found = remote.discover(init.io, init.gpa, init.minimal.environ, profile.destination(), null) catch |err| {
        if (json) {
            try writer.writeAll("{\"label\":");
            try control.writeJsonString(writer, profile.label());
            try writer.print(",\"reachable\":false,\"error\":\"{s}\"}}\n", .{@errorName(err)});
            try writer.flush();
        } else {
            std.debug.print("telar machine: {s} ({s}) is not reachable: {s}\n", .{ profile.label(), profile.destination(), @errorName(err) });
        }

        return failure;
    };

    const defaults = found.launchDefaults();
    const remote_schema: ?core.SchemaId = remote.schema(init.io, init.gpa, init.minimal.environ, profile.destination()) catch null;
    const compatible = if (remote_schema) |id| std.mem.eql(u8, &id, &core.schema_id) else false;
    const schema_text: []const u8 = if (remote_schema) |*id| id else "unknown";

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
    const detail = switch (err) {
        error.InsecureFile => "machines.json must be a regular file only its owner can read and write (chmod 600)",
        error.UnknownMachine => "no saved machine has that label; see `telar machine list`",
        error.DuplicateMachineLabel => "that label is already taken, by a saved machine or by this machine",
        error.TooManyMachines => "machines.json already holds the most machines it can",
        error.InvalidMachineLabel => "labels are 1 to 32 letters, digits, '.', '_' or '-', starting with a letter or a digit",
        error.InvalidMachineColor => "colors are #RRGGBB or a theme role such as red or accent",
        error.InvalidRemoteDestination => "destinations are an ssh host alias or user@host, without spaces or a leading '-'",
        error.InvalidMachineProfiles, error.IncompatibleMachineProfiles => "machines.json is not a file this telar can read",
        else => @errorName(err),
    };

    var buffer: [512]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "telar machine: {s}\n", .{detail}) catch return failure;
    std.Io.File.stderr().writeStreamingAll(init.io, message) catch {};
    return failure;
}

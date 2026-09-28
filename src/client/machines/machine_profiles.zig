//! Changing `machines.json` (docs/flows/machine-profiles.md): the one
//! procedure behind `telar machine add`, `remove`, `rename`, `enable` and
//! `disable` and the window's machine picker, which writes the file on a
//! worker. A change never touches a runtime; open windows follow the file.
const core = @import("telar-core");
const privatefile = @import("privatefile");
const std = @import("std");
const MachineEdit = @import("MachineEdit.zig");
const MachineEditJob = @import("MachineEditJob.zig");
const profile_file = @import("profile_file.zig");
const notifications = @import("../notifications/notifications.zig");
const Client = @import("../execution/Client.zig");

/// A new profile with a fresh id, refused when its label is this machine's.
///
/// ```zig
/// const profile = try machine_profiles.newProfile(io, &profiles, .{ .label = "box", .destination = "dev@box" });
/// ```
pub fn newProfile(io: std.Io, profiles: *const core.MachineProfiles, fields: core.MachineProfileFields) !core.MachineProfile {
    try requireNotLocal(profiles, fields.label);
    return core.MachineProfile.init(try core.MachineId.generate(io), fields);
}

/// Makes one change to loaded profiles.
///
/// ```zig
/// try machine_profiles.change(io, &profiles, .{ .kind = .disable, .label = "box" });
/// ```
pub fn change(io: std.Io, profiles: *core.MachineProfiles, edit: MachineEdit) !void {
    switch (edit.kind) {
        .add => try profiles.add(try newProfile(io, profiles, .{
            .label = edit.label,
            .destination = edit.value,
            .color = edit.color,
            .enabled = edit.enabled,
        })),
        .remove => try profiles.remove(edit.label),
        .rename => {
            try requireNotLocal(profiles, edit.value);
            try profiles.rename(edit.label, edit.value);
        },
        .enable => try profiles.enable(edit.label, true),
        .disable => try profiles.enable(edit.label, false),
        .place_telar => try profiles.placeTelar(edit.label, edit.value),
        .record_login => try profiles.recordLogin(edit.label, edit.login_agent, edit.login),
    }
}

/// Reads the file at `path`, makes one change and replaces the file, all
/// under the file's lock, so a change the CLI or another window makes
/// meanwhile waits for this one instead of being overwritten by it.
///
/// ```zig
/// try machine_profiles.store(io, gpa, path, .{ .kind = .remove, .label = "box" });
/// ```
pub fn store(io: std.Io, gpa: std.mem.Allocator, path: []const u8, edit: MachineEdit) !void {
    return storeAll(io, gpa, path, &.{edit});
}

/// Makes several changes as one: all of them reach the file, or none does
/// when one is refused.
///
/// ```zig
/// try machine_profiles.storeAll(io, gpa, path, &.{ add, place, enable });
/// ```
pub fn storeAll(io: std.Io, gpa: std.mem.Allocator, path: []const u8, edits: []const MachineEdit) !void {
    const held = try privatefile.lock(io, path);
    defer held.close(io);

    var profiles = try profile_file.load(io, gpa, path);
    for (edits) |edit| {
        try change(io, &profiles, edit);
    }

    try profile_file.save(io, path, &profiles);
}

/// Starts writing one change the person made in the window. The window's
/// watch of the file shows the result; a failure comes back as a notice.
/// A change asked for while another is written is refused with a notice.
///
/// ```zig
/// try machine_profiles.start(client, .{ .kind = .enable, .label = "box" });
/// ```
pub fn start(client: *Client, edit: MachineEdit) !void {
    if (client.machine_edit_pending) {
        return notifyFailure(client, "the previous machine change is still being saved");
    }

    if (edit.label.len > client.machine_edit_label.len or edit.value.len > client.machine_edit_value.len) {
        return notifyFailure(client, describe(error.InvalidMachineLabel));
    }

    const label = client.machine_edit_label[0..edit.label.len];
    @memcpy(label, edit.label);
    const value = client.machine_edit_value[0..edit.value.len];
    @memcpy(value, edit.value);

    client.machine_edit_pending = true;
    errdefer client.machine_edit_pending = false;
    try client.to_background.push(.{ .machine_edit = .{
        .edit = .{
            .kind = edit.kind,
            .label = label,
            .value = value,
        },
        .environ = client.options.environ,
    } });
}

/// Writes one change on a worker.
///
/// ```zig
/// const result = machine_profiles.write(io, gpa, job);
/// ```
pub fn write(io: std.Io, gpa: std.mem.Allocator, job: MachineEditJob) anyerror!void {
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path = try profile_file.path(job.environ, &path_buffer);
    try store(io, gpa, path, job.edit);
}

/// Takes a written change; a failure becomes a notice.
///
/// ```zig
/// try machine_profiles.finish(client, result);
/// ```
pub fn finish(client: *Client, result: anyerror!void) !void {
    client.machine_edit_pending = false;
    result catch |err| return notifyFailure(client, describe(err));
}

/// What a person reads for a failed change or an unreadable file.
///
/// ```zig
/// std.debug.print("telar machine: {s}\n", .{machine_profiles.describe(err)});
/// ```
pub fn describe(err: anyerror) []const u8 {
    return switch (err) {
        error.InsecureFile => "machines.json must be a regular file only its owner can read and write (chmod 600)",
        error.UnknownMachine => "no saved machine has that label; see `telar machine list`",
        error.DuplicateMachineLabel => "that label is already taken, by a saved machine or by this machine",
        error.DuplicateMachineDestination => "two saved machines cannot share one SSH destination",
        error.TooManyMachines => "machines.json already holds the most machines it can",
        error.InvalidMachineLabel => "labels are 1 to 32 letters, digits, '.', '_' or '-', starting with a letter or a digit",
        error.InvalidMachineColor => "colors are #RRGGBB or a theme role such as red or accent",
        error.InvalidRemoteDestination => "destinations are an ssh host alias or user@host, without spaces or a leading '-'",
        error.InvalidRemoteTelarPath => "telar paths are absolute and hold only letters, digits, '/', '.', '_', '+' or '-'",
        error.InvalidMachineProfiles => "machines.json is not a file this telar can read",
        error.IncompatibleMachineProfiles => "machines.json was written by a newer telar; update this one to read it",
        else => @errorName(err),
    };
}

fn notifyFailure(client: *Client, message: []const u8) !void {
    try notifications.publishNotificationNow(client, .{
        .level = .failure,
        .title = "Machine not saved",
        .message = message,
    });
}

fn requireNotLocal(profiles: *const core.MachineProfiles, label: []const u8) !void {
    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    if (std.mem.eql(u8, label, profile_file.localLabel(profiles, &buffer))) {
        return error.DuplicateMachineLabel;
    }
}

test "changes add, rename, disable and remove a machine but never take this machine's label" {
    var profiles: core.MachineProfiles = .{};
    var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const local = profile_file.localLabel(&profiles, &buffer);

    try change(std.testing.io, &profiles, .{ .kind = .add, .label = "box", .value = "dev@box" });
    try std.testing.expectError(error.DuplicateMachineLabel, change(std.testing.io, &profiles, .{ .kind = .add, .label = local, .value = "dev@other" }));
    try std.testing.expectError(error.DuplicateMachineLabel, change(std.testing.io, &profiles, .{ .kind = .rename, .label = "box", .value = local }));

    try change(std.testing.io, &profiles, .{ .kind = .rename, .label = "box", .value = "gpu" });
    try change(std.testing.io, &profiles, .{ .kind = .disable, .label = "gpu" });
    try std.testing.expect(!profiles.slice()[0].enabled);

    try change(std.testing.io, &profiles, .{ .kind = .place_telar, .label = "gpu", .value = "/home/dev/.local/share/telar/0.3.0/telar" });
    try std.testing.expectEqualStrings("/home/dev/.local/share/telar/0.3.0/telar", profiles.slice()[0].telarPath().?);
    try std.testing.expectError(error.InvalidRemoteTelarPath, change(std.testing.io, &profiles, .{ .kind = .place_telar, .label = "gpu", .value = "telar" }));

    try change(std.testing.io, &profiles, .{ .kind = .remove, .label = "gpu" });
    try std.testing.expectEqual(@as(usize, 0), profiles.slice().len);
}

test "changes stored at once by several writers all reach the file" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(std.testing.io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&path_buffer, "{s}/telar/{s}", .{ directory_buffer[0..directory_len], profile_file.file_name });

    const Writer = struct {
        fn run(path: []const u8, writer: usize, failures: *std.atomic.Value(u32)) void {
            for (0..adds_per_writer) |add| {
                var label_buffer: [8]u8 = undefined;
                const label = std.fmt.bufPrint(&label_buffer, "w{d}-{d}", .{ writer, add }) catch unreachable;
                store(std.testing.io, std.testing.allocator, path, .{ .kind = .add, .label = label, .value = label }) catch {
                    _ = failures.fetchAdd(1, .monotonic);
                };
            }
        }
    };

    var failures: std.atomic.Value(u32) = .init(0);
    var threads: [writers]std.Thread = undefined;
    for (&threads, 0..) |*thread, writer| {
        thread.* = try std.Thread.spawn(.{}, Writer.run, .{ file_path, writer, &failures });
    }

    for (threads) |thread| {
        thread.join();
    }

    const loaded = try profile_file.load(std.testing.io, std.testing.allocator, file_path);
    try std.testing.expectEqual(@as(u32, 0), failures.load(.monotonic));
    try std.testing.expectEqual(@as(u8, writers * adds_per_writer), loaded.count);
}

/// Writers and changes in the concurrent store test; together they fill
/// the file.
const writers = 4;
const adds_per_writer = core.MachineProfiles.capacity / writers;

//! `machines.json` on disk: where it lives, reading it and replacing it.
//! The CLI edits it and every window reads it; both go through here.
const core = @import("telar-core");
const privatefile = @import("privatefile");
const std = @import("std");
const config_directory = @import("../config/config_directory.zig");

/// The file's name inside the settings directory.
pub const file_name = "machines.json";
/// How long a window waits between looks at the file.
const poll_interval_s = 1;
/// Seeds the file's fingerprint; any fixed value works.
const fingerprint_seed = 0;

/// Resolves the file's path into `buffer`.
///
/// ```zig
/// const path = try profile_file.path(environ, &buffer);
/// ```
pub fn path(environ: std.process.Environ, buffer: []u8) ![]const u8 {
    return config_directory.path(environ, file_name, buffer);
}

/// Reads the saved profiles; a missing file is an empty list. A file anyone
/// else can read or write, a symlink, or an invalid file is an error.
///
/// ```zig
/// const profiles = try profile_file.load(io, gpa, path);
/// ```
pub fn load(io: std.Io, gpa: std.mem.Allocator, file_path: []const u8) !core.MachineProfiles {
    const source = try privatefile.read(io, gpa, file_path, .limited(core.MachineProfiles.max_file_bytes)) orelse return .{};
    defer gpa.free(source);

    return core.MachineProfiles.parse(gpa, source);
}

/// Replaces the file atomically and privately.
///
/// ```zig
/// try profile_file.save(io, path, &profiles);
/// ```
pub fn save(io: std.Io, file_path: []const u8, profiles: *const core.MachineProfiles) !void {
    var buffer: [core.MachineProfiles.max_file_bytes]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&buffer);
    try profiles.writeJson(&writer);

    try privatefile.replace(io, file_path, writer.buffered());
}

/// A cheap stamp of the file's metadata that changes when it is replaced,
/// written or removed.
///
/// ```zig
/// const seen = profile_file.fingerprint(io, path);
/// ```
pub fn fingerprint(io: std.Io, file_path: []const u8) u64 {
    return privatefile.fingerprint(io, file_path, fingerprint_seed);
}

/// Looks at the file once per interval until its fingerprint differs from
/// `known`, and returns the new one. A canceled wait returns `known`.
///
/// ```zig
/// const changed = profile_file.waitForChange(io, path, seen);
/// ```
pub fn waitForChange(io: std.Io, file_path: []const u8, known: u64) u64 {
    while (true) {
        io.sleep(.fromSeconds(poll_interval_s), .awake) catch return known;
        const current = fingerprint(io, file_path);
        if (current != known) {
            return current;
        }
    }
}

/// The label this machine answers to: the file's, or the host name.
///
/// ```zig
/// var buffer: [std.posix.HOST_NAME_MAX]u8 = undefined;
/// const local = profile_file.localLabel(&profiles, &buffer);
/// ```
pub fn localLabel(profiles: *const core.MachineProfiles, buffer: *[std.posix.HOST_NAME_MAX]u8) []const u8 {
    if (profiles.localLabel()) |label| {
        return label;
    }

    return std.posix.gethostname(buffer) catch "localhost";
}

test "profiles are saved privately and load back" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();

    var directory_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_len = try temp.dir.realPath(std.testing.io, &directory_buffer);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const file_path = try std.fmt.bufPrint(&path_buffer, "{s}/telar/{s}", .{ directory_buffer[0..directory_len], file_name });

    var profiles: core.MachineProfiles = .{};
    try profiles.add(try core.MachineProfile.init(@enumFromInt(1), .{
        .label = "box",
        .destination = "dev@box",
    }));
    try save(std.testing.io, file_path, &profiles);

    const loaded = try load(std.testing.io, std.testing.allocator, file_path);
    try std.testing.expectEqualStrings("dev@box", loaded.rows[0].destination());
}
